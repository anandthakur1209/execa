import Foundation

/// Phase 3.5b v2 dedup algorithm — extension on `SpeakerBleedDeduper`
/// carrying the containment + Porter-light stemming + concatenation
/// pre-pass + cross-validation post-pass. Lives in its own file so the
/// main `SpeakerBleedDeduper.swift` stays under the file-length cap
/// and so all v2-specific surface area is grouped for future
/// maintainers.
///
/// Order of passes inside `pairsToDedupV2`:
///   1. Concatenation pre-pass — groups consecutive same-speaker mic
///      segments that fall entirely within one system segment, joins
///      their text, scores once via containment. Flags the whole
///      group (one `DedupPair` per segment, all pointing at the same
///      `againstID`).
///   2. Pairwise pass — for each unflagged mic segment, finds the
///      first system segment with overlap ≥ 0.5 AND containment ≥
///      0.75 over stemmed tokens. Emits one `DedupPair` per match.
///   3. Cross-validation post-pass (commit d) — promotes the
///      remaining unflagged segments of any mic speaker who is
///      already ≥ 80% flagged with ≥ 3 absolute flagged segments.
extension SpeakerBleedDeduper {
    /// V2 orchestrator. See file header for pass ordering.
    static func pairsToDedupV2(segments: [Segment]) -> [DedupPair] {
        let mics = segments.filter { $0.source == "mic" }
        let systems = segments.filter { $0.source == "system" }
        guard !mics.isEmpty, !systems.isEmpty else { return [] }
        let prePassPairs = pairsFromConcatenationPrePass(mics: mics, systems: systems)
        let prePassFlagged = Set(prePassPairs.map(\.dedupedID))
        let pairwisePairs = pairwisePairsV2(
            mics: mics,
            systems: systems,
            excluding: prePassFlagged
        )
        return prePassPairs + pairwisePairs
    }

    /// V2 pairwise core: same gate as v1 but uses containment ≥ 0.75
    /// over **stemmed** tokens instead of jaccard. Each `DedupPair`
    /// carries both audit scores (containment is the decision;
    /// jaccard is informational only).
    private static func pairwisePairsV2(
        mics: [Segment],
        systems: [Segment],
        excluding: Set<Int64>
    ) -> [DedupPair] {
        mics.compactMap { mic in
            guard !excluding.contains(mic.id) else { return nil }
            guard isEligible(mic) else { return nil }
            for system in systems {
                guard isEligible(system) else { continue }
                guard timeOverlapFraction(mic: mic, system: system) >= minOverlapFraction else {
                    continue
                }
                let containment = containmentTextSimilarity(mic: mic.text, system: system.text)
                guard containment >= minContainment else { continue }
                let jaccard = jaccardTextSimilarity(mic.text, system.text)
                return DedupPair(
                    dedupedID: mic.id,
                    againstID: system.id,
                    containment: containment,
                    jaccard: jaccard,
                    promotionReason: .pairwise
                )
            }
            return nil
        }
    }

    // MARK: - Concatenation pre-pass (commit c)

    /// Groups consecutive same-speaker mic segments that fall entirely
    /// within one system segment's time window, joins their text in
    /// `startMs` order, and scores the joined string against the
    /// containing system segment. Each segment in the matched group
    /// gets its own `DedupPair` (one audit FK per soft-deleted row)
    /// pointing at the same system `againstID`, with
    /// `promotionReason: .concatenation`.
    ///
    /// Catches the "mic captured several short fragments of one long
    /// system utterance" pattern that pairwise misses because each
    /// fragment is individually below the containment threshold.
    static func pairsFromConcatenationPrePass(
        mics: [Segment],
        systems: [Segment]
    ) -> [DedupPair] {
        let groups = groupConsecutiveSameSpeaker(mics: mics)
        var result: [DedupPair] = []
        for group in groups {
            guard isEligibleGroup(group) else { continue }
            guard let containing = findContainingSystem(group: group, systems: systems) else {
                continue
            }
            guard isEligible(containing) else { continue }
            let joined = group
                .sorted { $0.startMs < $1.startMs }
                .map(\.text)
                .joined(separator: " ")
            let containment = containmentTextSimilarity(mic: joined, system: containing.text)
            guard containment >= minContainment else { continue }
            let jaccard = jaccardTextSimilarity(joined, containing.text)
            for segment in group {
                result.append(DedupPair(
                    dedupedID: segment.id,
                    againstID: containing.id,
                    containment: containment,
                    jaccard: jaccard,
                    promotionReason: .concatenation
                ))
            }
        }
        return result
    }

    /// Walks mic segments in `startMs` order and emits same-speaker
    /// runs of size ≥ 2. Speaker changes break the run; alternating
    /// speakers (A, B, A) emit two runs of size 1 (filtered out) for
    /// speaker A, not one run of size 2.
    static func groupConsecutiveSameSpeaker(mics: [Segment]) -> [[Segment]] {
        let sorted = mics.sorted { $0.startMs < $1.startMs }
        var runs: [[Segment]] = []
        var current: [Segment] = []
        var currentSpeaker: Int64?
        for segment in sorted {
            if segment.speakerID == currentSpeaker {
                current.append(segment)
            } else {
                if current.count >= 2 { runs.append(current) }
                current = [segment]
                currentSpeaker = segment.speakerID
            }
        }
        if current.count >= 2 { runs.append(current) }
        return runs
    }

    /// True iff the group passes the concat-pre-pass gates:
    /// total duration ≥ `minSegmentDurationMs` (NOT per-segment —
    /// the whole point of pre-pass is the segments are individually
    /// short), min non-NULL confidence ≥ `minConfidence` (NULLs
    /// proceed). The "entirely contained in one system segment"
    /// check lives in `findContainingSystem`.
    private static func isEligibleGroup(_ group: [Segment]) -> Bool {
        guard group.count >= 2 else { return false }
        let totalDuration = group.reduce(0) { $0 + $1.durationMs }
        guard totalDuration >= minSegmentDurationMs else { return false }
        let confidences = group.compactMap(\.confidence)
        if let minConf = confidences.min(), minConf < minConfidence { return false }
        return true
    }

    /// Returns the longest system segment whose time window
    /// **entirely contains** the group's combined window
    /// `[min(group.startMs), max(group.endMs)]`. Equal-length tie →
    /// lowest `id` for determinism. Nil if no system segment fully
    /// contains the group.
    static func findContainingSystem(
        group: [Segment],
        systems: [Segment]
    ) -> Segment? {
        guard !group.isEmpty else { return nil }
        let groupStart = group.map(\.startMs).min() ?? 0
        let groupEnd = group.map(\.endMs).max() ?? 0
        let candidates = systems.filter { sys in
            sys.startMs <= groupStart && sys.endMs >= groupEnd
        }
        return candidates.max { lhs, rhs in
            if lhs.durationMs != rhs.durationMs {
                return lhs.durationMs < rhs.durationMs
            }
            // Higher durationMs wins; on tie, LOWER id wins (so we
            // invert the id comparison to make `max` return lowest).
            return lhs.id > rhs.id
        }
    }

    // MARK: - V2 scoring primitives

    /// Containment coefficient: `|mic_tokens ∩ system_tokens| /
    /// |mic_tokens|`, computed over STEMMED tokens. Returns 0 if the
    /// mic side tokenizes to empty (defensive — divide-by-zero would
    /// otherwise NaN). Asymmetric by design: "what fraction of the
    /// mic's vocabulary appears in the system's vocabulary." A mic
    /// fragment of a larger system utterance hits 1.0; a paraphrase
    /// with different word choice stays low.
    static func containmentTextSimilarity(mic: String, system: String) -> Double {
        let micTokens = Set(tokenList(mic))
        let systemTokens = Set(tokenList(system))
        guard !micTokens.isEmpty else { return 0 }
        let intersectionCount = micTokens.intersection(systemTokens).count
        return Double(intersectionCount) / Double(micTokens.count)
    }

    /// Ordered list of stemmed tokens. v2 uses this instead of the
    /// `Set<String>`-returning `tokenize(_:)` because the concatenation
    /// pre-pass needs to preserve order before joining; containment
    /// scoring builds sets at the call site. Stemming is ASCII-only —
    /// see `stem(_:)`.
    static func tokenList(_ text: String) -> [String] {
        let lower = text.lowercased()
        let separators = CharacterSet.alphanumerics.inverted
        return lower
            .components(separatedBy: separators)
            .filter { !$0.isEmpty }
            .map { stem($0) }
    }

    /// Porter-light suffix stripper, ASCII-only. Six rules applied in
    /// precedence order; first match wins and the rule returns. Each
    /// rule has a minimum-input-length guard so common short words
    /// (`his`, `was`, `yes`, `ring`, `fed`, `bed`, `uses`) don't get
    /// catastrophically over-stemmed. Devanagari and other non-ASCII
    /// tokens pass through untouched — the gate is
    /// `String.allSatisfy(\.isASCII)`.
    ///
    /// Rules (input-length guards; result lengths follow trivially):
    ///   1. "ies" → "y"  (input ≥ 5): "companies" → "company"
    ///   2. "ied" → "y"  (input ≥ 5): "tried" → "try"
    ///   3. "ing" → ""   (input ≥ 7): "training" → "train"; "ring" stays
    ///   4. "ed"  → ""   (input ≥ 6): "trained" → "train"; "fed", "bed" stay
    ///   5. "es"  → ""   (input ≥ 5): "boxes" → "box"
    ///   6. "s"   → ""   (input ≥ 5): "scripts" → "script"; "his", "was", "uses" stay
    static func stem(_ token: String) -> String {
        guard token.allSatisfy(\.isASCII) else { return token }
        let chars = Array(token)
        let count = chars.count

        if count >= 5, chars.suffix(3) == ["i", "e", "s"] {
            return String(chars.dropLast(3)) + "y"
        }
        if count >= 5, chars.suffix(3) == ["i", "e", "d"] {
            return String(chars.dropLast(3)) + "y"
        }
        if count >= 7, chars.suffix(3) == ["i", "n", "g"] {
            return String(chars.dropLast(3))
        }
        if count >= 6, chars.suffix(2) == ["e", "d"] {
            return String(chars.dropLast(2))
        }
        if count >= 5, chars.suffix(2) == ["e", "s"] {
            return String(chars.dropLast(2))
        }
        if count >= 5, chars.last == "s" {
            return String(chars.dropLast(1))
        }
        return token
    }
}
