import Foundation
import GRDB

/// Post-batch dedup pass that removes mic-side `transcript_segments`
/// rows mirroring system-side rows in time AND text — the deterministic
/// alternative to AEC for speaker-mode meetings (DECISIONS.md
/// Phase 3.5 + 2026-05-11 Phase 3.5b entries). Soft-delete via the
/// `transcript_segments.deduped_against_segment_id` column added in v4
/// migration: flagged rows stay in the DB for audit; rendering queries
/// filter them out via `WHERE deduped_against_segment_id IS NULL`.
///
/// Phase 3.5 shipped v1 of the algorithm (Jaccard similarity at 0.6).
/// Phase 3.5b commit (a) introduces the algorithm-version plumbing:
/// `pairsToDedup` now dispatches on a `BleedDedupAlgorithmVersion`
/// parameter. `pairsToDedupV1(segments:)` carries the unchanged v1
/// logic. `pairsToDedupV2(segments:)` is a placeholder that delegates
/// to v1 in commit (a); commits (b)/(c)/(d) replace its body with the
/// containment + stemming + concatenation + cross-validation
/// algorithm. The default in `SettingsStore.bleedDedupAlgorithmVersion`
/// stays `.v1` for commit (a); it flips to `.v2` in commit (b).
///
/// Direction is ALWAYS one-way: mic flagged as bleed of system. The
/// reverse is rare (the user's voice doesn't loop back through the
/// system audio path) and bidirectional dedup risks losing legitimate
/// mic speech. See Decision 3 in the Phase 3.5 plan.
enum SpeakerBleedDeduper {
    // MARK: - Thresholds (v1 / shared with v2)

    /// Time-overlap fraction below which dedup never fires.
    static let minOverlapFraction: Double = 0.5

    /// Jaccard text-similarity floor used by the v1 path. v2 uses
    /// `minContainment` instead (lands in commit b).
    static let minTextSimilarity: Double = 0.6

    /// Segments shorter than this on either side are too noisy to
    /// compare; skip dedup. 1 second is the empirical floor: anything
    /// shorter is breath, mouse clicks, or single-syllable utterances
    /// whose transcripts aren't reliable enough for a similarity
    /// match to be meaningful.
    static let minSegmentDurationMs: Int = 1000

    /// Confidence floor on either side. NULL is treated as "no
    /// information available, proceed" — Sarvam batch may not always
    /// emit confidence, and blocking dedup on NULL would defeat the
    /// purpose. A value of 0.59 explicitly skips; 0.6 is the boundary.
    static let minConfidence: Double = 0.6

    // MARK: - Thresholds (v2-specific)

    /// Containment coefficient floor used by v2: `|mic ∩ system| /
    /// |mic|`. Tighter than v1's jaccard 0.6 because containment is a
    /// stricter measure when bleed is real — a mic fragment of a
    /// longer system segment hits 1.0 containment but only 0.33
    /// jaccard. 0.75 is the Phase 3.5b plan-locked default.
    static let minContainment: Double = 0.75

    /// Fraction of a mic speaker's segments that must be flagged by
    /// pairwise + concatenation before the cross-validation post-pass
    /// promotes the speaker's remaining unflagged segments. 80% is the
    /// Phase 3.5b plan-locked default. Paired with
    /// `crossValidationMinFlagged` to defend against false promotion
    /// on speakers with very few segments.
    static let crossValidationFlagRatio: Double = 0.8

    /// Minimum absolute number of flagged segments required for the
    /// cross-validation post-pass to fire. 3 protects 1- and 2-
    /// segment mic speakers from being whole-promoted on insufficient
    /// evidence (a single-segment speaker would always hit 100% flag
    /// ratio after one pairwise match, but one match isn't enough
    /// to conclude "whole speaker is bleed").
    static let crossValidationMinFlagged: Int = 3

    // MARK: - Types

    /// One mic-or-system segment as the deduper sees it. Built from
    /// `transcript_segments` rows for one meeting. The `id` is the
    /// `transcript_segments.id` (used to write
    /// `deduped_against_segment_id`); `speakerID` is the raw
    /// `speakers.id` (the FK target on `transcript_segments.speaker_id`);
    /// `effectiveSpeakerID` is the post-merge canonical speaker —
    /// equal to `speakerID` for un-merged rows, equal to
    /// `merged_into_speaker_id` for rows merged into another speaker
    /// (Phase 3.5c merge-aware grouping). Single-hop alias resolution
    /// matches `SpeakerQueries.visibleSpeakers`; multi-hop chains
    /// (A→B→C) are deliberately not flattened here.
    struct Segment: Equatable {
        let id: Int64
        let speakerID: Int64
        let effectiveSpeakerID: Int64
        let source: String
        let startMs: Int
        let endMs: Int
        let text: String
        let confidence: Double?

        var durationMs: Int {
            max(0, endMs - startMs)
        }
    }

    // MARK: - DB entry point

    /// Runs the dedup pass for one meeting under the given algorithm
    /// `version`. Caller wraps the call in a
    /// `database.queue.write { db in ... }` block; this function reads
    /// + writes against `db` directly. Returns a `DedupResult` for
    /// logging / test assertions.
    static func dedup(
        meetingID: String,
        version: BleedDedupAlgorithmVersion,
        in db: GRDB.Database
    ) throws -> DedupResult {
        // Reset-first idempotency (Phase 3.5c). Every call re-derives
        // dedup state from scratch against the CURRENT speaker
        // topology + segment text. At swap time this is a no-op
        // because the swap deletes + re-inserts segments so their
        // `deduped_against_segment_id` is already NULL; on a merge /
        // split-triggered re-run, the wipe clears the stale FKs so
        // the re-derivation against the new effective topology is
        // clean. Documented in DECISIONS 2026-05-12 Phase 3.5c entry.
        try db.execute(
            sql: """
            UPDATE transcript_segments
            SET deduped_against_segment_id = NULL
            WHERE meeting_id = ?
            """,
            arguments: [meetingID]
        )
        let segments = try loadSegments(meetingID: meetingID, in: db)
        let pairs = pairsToDedup(segments: segments, version: version)
        for pair in pairs {
            try db.execute(
                sql: """
                UPDATE transcript_segments
                SET deduped_against_segment_id = ?
                WHERE id = ?
                """,
                arguments: [pair.againstID, pair.dedupedID]
            )
        }
        return DedupResult(pairs: pairs)
    }

    // MARK: - Algorithm dispatcher

    /// Pure-function core. Given the meeting's segments and an
    /// algorithm version, returns the `DedupPair`s that should be
    /// soft-deleted. No DB access; testable in isolation. Callers do
    /// the SQL UPDATEs via `dedup(meetingID:version:in:)`.
    static func pairsToDedup(
        segments: [Segment],
        version: BleedDedupAlgorithmVersion = .v2
    ) -> [DedupPair] {
        switch version {
        case .v1: pairsToDedupV1(segments: segments)
        case .v2: pairsToDedupV2(segments: segments)
        }
    }

    // MARK: - V1: Jaccard pairwise (Phase 3.5 algorithm, unchanged)

    /// V1 (Phase 3.5): pairwise pass using Jaccard similarity at 0.6
    /// threshold. Kept untouched as a flag-fallback when
    /// `bleed_dedup_algorithm_version = "v1"`. Audit pairs carry the
    /// jaccard score; containment is computed and stored too so the
    /// audit fields are symmetric across versions.
    static func pairsToDedupV1(segments: [Segment]) -> [DedupPair] {
        let mics = segments.filter { $0.source == "mic" }
        let systems = segments.filter { $0.source == "system" }
        guard !mics.isEmpty, !systems.isEmpty else { return [] }
        return mics.compactMap { mic in
            guard isEligible(mic) else { return nil }
            guard let match = systems.first(where: { isMatchV1(mic: mic, system: $0) }) else {
                return nil
            }
            let jaccard = jaccardTextSimilarity(mic.text, match.text)
            return DedupPair(
                dedupedID: mic.id,
                againstID: match.id,
                containment: nil,
                jaccard: jaccard,
                promotionReason: .pairwise
            )
        }
    }

    // V2 algorithm + helpers live in SpeakerBleedDedupV2.swift as an
    // extension on this enum. Keeps the main file under the cap and
    // groups all v2-specific surface area in one place for future
    // maintainers.

    // MARK: - Eligibility + V1 matching

    /// True iff the segment passes the duration / confidence / non-
    /// empty-text gate that applies to BOTH sides of a candidate pair.
    /// Default-internal so the v2 extension in
    /// `SpeakerBleedDedupV2.swift` can reach it; the gate is shared
    /// across versions, so single-source-of-truth wins over privacy.
    static func isEligible(_ segment: Segment) -> Bool {
        guard segment.durationMs >= minSegmentDurationMs else { return false }
        if let conf = segment.confidence, conf < minConfidence { return false }
        return !segment.text.isEmpty
    }

    /// V1: `system` is eligible AND meets both the time-overlap and
    /// jaccard-similarity thresholds against `mic`.
    private static func isMatchV1(mic: Segment, system: Segment) -> Bool {
        guard isEligible(system) else { return false }
        guard timeOverlapFraction(mic: mic, system: system) >= minOverlapFraction else { return false }
        return jaccardTextSimilarity(mic.text, system.text) >= minTextSimilarity
    }

    // MARK: - Shared scoring primitives

    /// Time-overlap fraction relative to `min(mic_duration,
    /// system_duration)`. Returns 0.0 if either duration is 0.
    static func timeOverlapFraction(mic: Segment, system: Segment) -> Double {
        let micDur = mic.durationMs
        let systemDur = system.durationMs
        guard micDur > 0, systemDur > 0 else { return 0 }
        let overlapStart = max(mic.startMs, system.startMs)
        let overlapEnd = min(mic.endMs, system.endMs)
        let overlap = max(0, overlapEnd - overlapStart)
        let denominator = Double(min(micDur, systemDur))
        guard denominator > 0 else { return 0 }
        return Double(overlap) / denominator
    }

    /// Jaccard text similarity over lowercased, unicode-tokenized
    /// word sets. Returns 0 if either side tokenizes to empty (an
    /// empty mic.text or system.text would otherwise produce a
    /// vacuous "1.0 jaccard of empty sets" — defensive 0 means
    /// "no signal, don't dedup").
    static func jaccardTextSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let tokensA = tokenize(lhs)
        let tokensB = tokenize(rhs)
        guard !tokensA.isEmpty, !tokensB.isEmpty else { return 0 }
        let intersectionCount = tokensA.intersection(tokensB).count
        let unionCount = tokensA.union(tokensB).count
        guard unionCount > 0 else { return 0 }
        return Double(intersectionCount) / Double(unionCount)
    }

    /// Splits text on unicode whitespace + punctuation into lowercased
    /// non-empty tokens. Devanagari and other non-ASCII scripts work
    /// because we use `CharacterSet.alphanumerics.inverted` for the
    /// split (Foundation respects unicode general categories). No
    /// stemming — v1 used this directly; v2 (commit b) introduces
    /// `tokenList(_:)` alongside that applies the Porter-light
    /// stemmer.
    static func tokenize(_ text: String) -> Set<String> {
        let lower = text.lowercased()
        let separators = CharacterSet.alphanumerics.inverted
        return Set(
            lower
                .components(separatedBy: separators)
                .filter { !$0.isEmpty }
        )
    }

    // MARK: - DB loading

    /// Loads every final segment for the meeting, joined to its
    /// speaker row so we get `source` + the post-merge canonical
    /// speaker via `COALESCE(merged_into_speaker_id, speakers.id)`.
    /// Does NOT filter on `deduped_against_segment_id` — `dedup` has
    /// already reset that column to NULL for the meeting. Single-hop
    /// alias resolution matches `SpeakerQueries.visibleSpeakers`;
    /// multi-hop chains (A→B→C) are an accepted edge case (Phase 3.5c
    /// DECISIONS entry).
    private static func loadSegments(meetingID: String, in db: GRDB.Database) throws -> [Segment] {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT t.id AS id,
                   t.speaker_id AS speaker_id,
                   t.start_ms AS start_ms,
                   t.end_ms AS end_ms,
                   t.text AS text,
                   t.confidence AS confidence,
                   s.source AS source,
                   COALESCE(s.merged_into_speaker_id, s.id) AS effective_speaker_id
            FROM transcript_segments t
            JOIN speakers s ON s.id = t.speaker_id
            WHERE t.meeting_id = ? AND t.is_final = 1
            """,
            arguments: [meetingID]
        )
        return rows.compactMap { row -> Segment? in
            guard let id: Int64 = row["id"],
                  let speakerID: Int64 = row["speaker_id"],
                  let effectiveSpeakerID: Int64 = row["effective_speaker_id"],
                  let source: String = row["source"],
                  let startMs: Int = row["start_ms"],
                  let endMs: Int = row["end_ms"],
                  let text: String = row["text"]
            else { return nil }
            return Segment(
                id: id,
                speakerID: speakerID,
                effectiveSpeakerID: effectiveSpeakerID,
                source: source,
                startMs: startMs,
                endMs: endMs,
                text: text,
                confidence: row["confidence"]
            )
        }
    }
}

// `BleedDedupAlgorithmVersion`, `PromotionReason`, `DedupPair`, and
// `DedupResult` are defined in SpeakerBleedDedupTypes.swift.
