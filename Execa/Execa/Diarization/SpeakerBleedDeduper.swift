import Foundation
import GRDB

/// Post-batch dedup pass that removes mic-side `transcript_segments`
/// rows mirroring system-side rows in time AND text — the deterministic
/// alternative to AEC for speaker-mode meetings (DECISIONS.md
/// Phase 3.5 entry). Soft-delete via the
/// `transcript_segments.deduped_against_segment_id` column added in v4
/// migration: flagged rows stay in the DB for audit; rendering queries
/// filter them out via `WHERE deduped_against_segment_id IS NULL`.
///
/// Algorithm (per mic-side segment M, against each system-side
/// segment S in the same meeting):
///
///   1. Skip if either segment's duration < `minSegmentDurationMs`.
///   2. Skip if either segment has confidence below `minConfidence`
///      (NULL confidence proceeds — Sarvam batch may not always emit).
///   3. Skip if neither side has non-empty text (jaccard would be 0
///      anyway; cheap fast-path).
///   4. Skip if `timeOverlapFraction(M, S) < minOverlapFraction`.
///      Overlap is computed against `min(mic_dur, system_dur)` —
///      "this short mic segment was captured during this longer
///      system segment" is the bleed-through pattern.
///   5. Skip if `jaccardTextSimilarity(M.text, S.text) < minTextSimilarity`.
///   6. Otherwise flag M as bleed-of-S; on post-pass, set
///      `M.deduped_against_segment_id = S.id`.
///
/// Direction: ONLY mic→system (mic flagged as bleed of system). The
/// reverse is rare in practice (the user's voice doesn't loop back
/// through the system audio path) and the bidirectional case risks
/// losing legitimate mic-side speech. See Decision 3 in the Phase 3.5
/// plan.
///
/// This commit (Phase 3.5 commit 1) ships the type + thresholds + a
/// stub `dedup` that returns an empty result. Algorithm + tests land
/// in commit 2; DB integration lands in commit 3.
enum SpeakerBleedDeduper {
    /// Time-overlap fraction below which dedup never fires.
    static let minOverlapFraction: Double = 0.5

    /// Jaccard text-similarity below which dedup never fires.
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

    /// One mic-or-system segment as the deduper sees it. Built from
    /// `transcript_segments` rows for one meeting. The `id` is the
    /// `transcript_segments.id` (used to write
    /// `deduped_against_segment_id`); `speakerID` is the
    /// `speakers.id` (used in commit 3 when filtering orphans).
    struct Segment: Equatable {
        let id: Int64
        let speakerID: Int64
        let source: String
        let startMs: Int
        let endMs: Int
        let text: String
        let confidence: Double?
    }

    /// Runs the dedup pass for one meeting. Caller wraps the call in
    /// a `database.queue.write { db in ... }` block; this function
    /// reads + writes against `db` directly. Returns a `DedupResult`
    /// for logging / test assertions.
    ///
    /// Stub for now — real implementation lands in Phase 3.5 commit 2
    /// once the boundary-test coverage of the pure-function helpers is
    /// in place.
    static func dedup(meetingID _: String, in _: GRDB.Database) throws -> DedupResult {
        DedupResult(dedupedPairs: [])
    }

    /// Time-overlap fraction relative to `min(mic_duration,
    /// system_duration)`. Stub — implementation in commit 2.
    static func timeOverlapFraction(mic _: Segment, system _: Segment) -> Double {
        0
    }

    /// Jaccard text similarity over lowercased, unicode-tokenized
    /// word sets. Stub — implementation in commit 2.
    static func jaccardTextSimilarity(_: String, _: String) -> Double {
        0
    }

    /// Tokenize for Jaccard. Stub — implementation in commit 2.
    static func tokenize(_: String) -> Set<String> {
        []
    }
}

/// Result of one dedup pass. `dedupedPairs[i] = (deduped_segment_id,
/// against_segment_id)` — the mic-side row that got soft-deleted and
/// the system-side row it points at. Empty array means no-op
/// (single-source meeting, empty meeting, or no pair met both
/// thresholds).
struct DedupResult: Equatable {
    let dedupedPairs: [(Int64, Int64)]

    static func == (lhs: DedupResult, rhs: DedupResult) -> Bool {
        guard lhs.dedupedPairs.count == rhs.dedupedPairs.count else { return false }
        for (lp, rp) in zip(lhs.dedupedPairs, rhs.dedupedPairs) where lp != rp {
            return false
        }
        return true
    }
}
