import Foundation

/// Phase 3.5b v2 dedup algorithm — extension on `SpeakerBleedDeduper`
/// carrying the containment + Porter-light stemming + concatenation
/// pre-pass + cross-validation post-pass.
///
/// Phase 3.5c made every pass **merge-aware**: system segments are
/// grouped by post-merge effective speaker ID (`Segment.
/// effectiveSpeakerID`, set by `loadSegments`'s JOIN+COALESCE). The
/// pairwise pass and the concat pre-pass score the mic side against
/// the effective speaker's **combined text** (constituent segments
/// joined in `startMs` order). The audit FK still anchors on a
/// specific `transcript_segments.id` — the best-overlap constituent
/// segment of the matched effective speaker — so the durable DB
/// pointer survives merge/split/unmerge regardless. Cross-validation
/// groups its target-speaker counts by effective speaker so matches
/// that previously scattered across over-segmented Sarvam output
/// consolidate after a manual merge.
///
/// Order of passes inside `pairsToDedupV2`:
///   1. Concatenation pre-pass — groups consecutive same-speaker mic
///      segments and matches them against the effective system
///      speaker whose combined time window contains the group.
///   2. Pairwise pass — for each unflagged mic segment, finds an
///      effective system speaker with overlap ≥ 0.5 AND containment
///      ≥ 0.75 over stemmed tokens of the combined system text.
///   3. Cross-validation post-pass — promotes the remaining unflagged
///      segments of any mic speaker who is already ≥ 80% flagged
///      with ≥ 3 absolute flagged segments, against the most-
///      frequent EFFECTIVE system speaker.
extension SpeakerBleedDeduper {
    /// V2 orchestrator. See file header for pass ordering.
    static func pairsToDedupV2(segments: [Segment]) -> [DedupPair] {
        let mics = segments.filter { $0.source == "mic" }
        let systems = segments.filter { $0.source == "system" }
        guard !mics.isEmpty, !systems.isEmpty else { return [] }
        let effectiveSystems = buildEffectiveSystemSpeakers(systems: systems)
        guard !effectiveSystems.isEmpty else { return [] }
        let prePassPairs = pairsFromConcatenationPrePass(
            mics: mics,
            effectiveSystems: effectiveSystems
        )
        let prePassFlagged = Set(prePassPairs.map(\.dedupedID))
        let pairwisePairs = pairwisePairsV2(
            mics: mics,
            effectiveSystems: effectiveSystems,
            excluding: prePassFlagged
        )
        let initialPairs = prePassPairs + pairwisePairs
        let promotedPairs = applySpeakerLevelPromotion(
            pairs: initialPairs,
            mics: mics,
            systems: systems
        )
        return initialPairs + promotedPairs
    }

    /// V2 pairwise core: iterates **effective system speakers** (post-
    /// merge grouping). For each mic segment, scores `containmentText
    /// Similarity(mic.text, effective.combinedText)`. Time overlap
    /// gate uses the max overlap fraction across any constituent
    /// segment. Audit FK anchors on `bestOverlapSegment` — the
    /// constituent system segment with the highest time-overlap
    /// fraction against the mic; tie → longest, then lowest id.
    private static func pairwisePairsV2(
        mics: [Segment],
        effectiveSystems: [EffectiveSystemSpeaker],
        excluding: Set<Int64>
    ) -> [DedupPair] {
        mics.compactMap { mic in
            guard !excluding.contains(mic.id) else { return nil }
            guard isEligible(mic) else { return nil }
            for effective in effectiveSystems {
                let eligibleSegments = effective.segments.filter { isEligible($0) }
                guard !eligibleSegments.isEmpty else { continue }
                let overlap = maxOverlapFraction(mic: mic, candidates: eligibleSegments)
                guard overlap >= minOverlapFraction else { continue }
                let containment = containmentTextSimilarity(
                    mic: mic.text,
                    system: effective.combinedText
                )
                guard containment >= minContainment else { continue }
                guard let anchor = bestOverlapSegment(
                    for: mic,
                    in: eligibleSegments
                ) else { continue }
                let jaccard = jaccardTextSimilarity(mic.text, effective.combinedText)
                return DedupPair(
                    dedupedID: mic.id,
                    againstID: anchor.id,
                    containment: containment,
                    jaccard: jaccard,
                    promotionReason: .pairwise
                )
            }
            return nil
        }
    }

    // MARK: - Concatenation pre-pass

    /// Convenience overload taking raw `[Segment]` for system inputs;
    /// builds `[EffectiveSystemSpeaker]` internally. Used by tests
    /// that exercise the pre-pass against synthetic un-merged data
    /// (effective == raw for every segment).
    static func pairsFromConcatenationPrePass(
        mics: [Segment],
        systems: [Segment]
    ) -> [DedupPair] {
        pairsFromConcatenationPrePass(
            mics: mics,
            effectiveSystems: buildEffectiveSystemSpeakers(systems: systems)
        )
    }

    /// Groups consecutive same-speaker mic segments and matches them
    /// against the effective system speaker whose union-of-segments
    /// time window entirely contains the group. Each segment in the
    /// matched group gets its own `DedupPair` with the same audit
    /// `againstID` (the best-overlap constituent segment).
    static func pairsFromConcatenationPrePass(
        mics: [Segment],
        effectiveSystems: [EffectiveSystemSpeaker]
    ) -> [DedupPair] {
        let groups = groupConsecutiveSameSpeaker(mics: mics)
        var result: [DedupPair] = []
        for group in groups {
            guard isEligibleGroup(group) else { continue }
            guard let effective = findContainingEffectiveSpeaker(
                group: group,
                effectiveSystems: effectiveSystems
            ) else { continue }
            let eligibleSegments = effective.segments.filter { isEligible($0) }
            guard !eligibleSegments.isEmpty else { continue }
            let joined = group
                .sorted { $0.startMs < $1.startMs }
                .map(\.text)
                .joined(separator: " ")
            let containment = containmentTextSimilarity(
                mic: joined,
                system: effective.combinedText
            )
            guard containment >= minContainment else { continue }
            let groupStart = group.map(\.startMs).min() ?? 0
            let groupEnd = group.map(\.endMs).max() ?? 0
            let probe = Segment(
                id: -1,
                speakerID: -1,
                effectiveSpeakerID: -1,
                source: "mic",
                startMs: groupStart,
                endMs: groupEnd,
                text: "",
                confidence: nil
            )
            guard let anchor = bestOverlapSegment(
                for: probe,
                in: eligibleSegments
            ) else { continue }
            let jaccard = jaccardTextSimilarity(joined, effective.combinedText)
            for segment in group {
                result.append(DedupPair(
                    dedupedID: segment.id,
                    againstID: anchor.id,
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
    /// proceed). The "entirely contained" check lives in
    /// `findContainingEffectiveSpeaker`.
    private static func isEligibleGroup(_ group: [Segment]) -> Bool {
        guard group.count >= 2 else { return false }
        let totalDuration = group.reduce(0) { $0 + $1.durationMs }
        guard totalDuration >= minSegmentDurationMs else { return false }
        let confidences = group.compactMap(\.confidence)
        if let minConf = confidences.min(), minConf < minConfidence { return false }
        return true
    }

    /// Phase 3.5c replacement for `findContainingSystem`. Returns the
    /// effective system speaker whose union-of-segments time window
    /// entirely contains the group's combined window. Tie-break:
    /// longest total coverage first; equal coverage → lowest
    /// `effectiveID` (deterministic). Nil if no effective speaker
    /// fully contains the group.
    static func findContainingEffectiveSpeaker(
        group: [Segment],
        effectiveSystems: [EffectiveSystemSpeaker]
    ) -> EffectiveSystemSpeaker? {
        guard !group.isEmpty else { return nil }
        let groupStart = group.map(\.startMs).min() ?? 0
        let groupEnd = group.map(\.endMs).max() ?? 0
        let candidates = effectiveSystems.filter { effective in
            effective.earliestStart <= groupStart && effective.latestEnd >= groupEnd
        }
        return candidates.max { lhs, rhs in
            if lhs.totalCoverageMs != rhs.totalCoverageMs {
                return lhs.totalCoverageMs < rhs.totalCoverageMs
            }
            // Higher coverage wins; tie → LOWER id wins.
            return lhs.effectiveID > rhs.effectiveID
        }
    }

    /// Max time-overlap fraction across `candidates`. Used by
    /// pairwise as the gate before computing containment; if no
    /// constituent segment overlaps the mic at ≥ `minOverlapFraction`,
    /// the effective speaker is skipped.
    private static func maxOverlapFraction(
        mic: Segment,
        candidates: [Segment]
    ) -> Double {
        candidates
            .map { timeOverlapFraction(mic: mic, system: $0) }
            .max() ?? 0
    }

    /// Picks the constituent system segment with the highest time-
    /// overlap fraction against `mic`. Tie → longest, then lowest id.
    /// Used to anchor the audit FK on a specific segment after the
    /// effective-speaker-level match decision.
    static func bestOverlapSegment(
        for mic: Segment,
        in candidates: [Segment]
    ) -> Segment? {
        guard !candidates.isEmpty else { return nil }
        return candidates.max { lhs, rhs in
            let lhsOverlap = timeOverlapFraction(mic: mic, system: lhs)
            let rhsOverlap = timeOverlapFraction(mic: mic, system: rhs)
            if lhsOverlap != rhsOverlap { return lhsOverlap < rhsOverlap }
            if lhs.durationMs != rhs.durationMs { return lhs.durationMs < rhs.durationMs }
            return lhs.id > rhs.id // invert so `max` returns lowest id
        }
    }

    // MARK: - EffectiveSystemSpeaker builder

    /// Groups system segments by post-merge effective speaker.
    /// Constituent segments are sorted by `startMs`; the combined
    /// text is joined in that order with a single space separator.
    static func buildEffectiveSystemSpeakers(
        systems: [Segment]
    ) -> [EffectiveSystemSpeaker] {
        let grouped = Dictionary(grouping: systems, by: \.effectiveSpeakerID)
        return grouped.map { effectiveID, segments in
            let sorted = segments.sorted { $0.startMs < $1.startMs }
            let combined = sorted.map(\.text).joined(separator: " ")
            let earliestStart = sorted.first?.startMs ?? 0
            let latestEnd = sorted.map(\.endMs).max() ?? 0
            let totalCoverage = sorted.reduce(0) { $0 + $1.durationMs }
            return EffectiveSystemSpeaker(
                effectiveID: effectiveID,
                segments: sorted,
                combinedText: combined,
                earliestStart: earliestStart,
                latestEnd: latestEnd,
                totalCoverageMs: totalCoverage
            )
        }
        .sorted { $0.effectiveID < $1.effectiveID } // deterministic iteration
    }

    // Cross-validation post-pass (`applySpeakerLevelPromotion` +
    // helpers) lives in `SpeakerBleedDedupV2CrossValidation.swift`.
    // Scoring primitives (`containmentTextSimilarity`, `tokenList`,
    // `stem`) live in `SpeakerBleedDedupScoring.swift`.
}

/// Aggregate view of all system segments belonging to one
/// post-merge effective speaker. Built fresh on each `dedup` call by
/// `buildEffectiveSystemSpeakers`. Carries the joined text + the time
/// envelope so pairwise + concat pre-pass + cross-validation can
/// score against the consolidated picture instead of per-raw-speaker.
struct EffectiveSystemSpeaker: Equatable {
    let effectiveID: Int64
    let segments: [SpeakerBleedDeduper.Segment]
    let combinedText: String
    let earliestStart: Int
    let latestEnd: Int
    let totalCoverageMs: Int
}
