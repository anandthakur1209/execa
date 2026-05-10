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
    /// `speakers.id` (used by view-layer filters when listing
    /// orphan speakers).
    struct Segment: Equatable {
        let id: Int64
        let speakerID: Int64
        let source: String
        let startMs: Int
        let endMs: Int
        let text: String
        let confidence: Double?

        var durationMs: Int {
            max(0, endMs - startMs)
        }
    }

    /// Runs the dedup pass for one meeting. Caller wraps the call in
    /// a `database.queue.write { db in ... }` block; this function
    /// reads + writes against `db` directly. Returns a `DedupResult`
    /// for logging / test assertions.
    static func dedup(meetingID: String, in db: GRDB.Database) throws -> DedupResult {
        let segments = try loadSegments(meetingID: meetingID, in: db)
        let pairs = pairsToDedup(segments: segments)
        for (dedupedID, againstID) in pairs {
            try db.execute(
                sql: """
                UPDATE transcript_segments
                SET deduped_against_segment_id = ?
                WHERE id = ?
                """,
                arguments: [againstID, dedupedID]
            )
        }
        return DedupResult(dedupedPairs: pairs)
    }

    /// Pure-function core. Given the meeting's segments, returns the
    /// list of `(mic_segment_id, system_segment_id)` pairs that
    /// should be soft-deleted. No DB access; testable in isolation.
    /// Callers do the SQL UPDATEs.
    static func pairsToDedup(segments: [Segment]) -> [(Int64, Int64)] {
        let mics = segments.filter { $0.source == "mic" }
        let systems = segments.filter { $0.source == "system" }
        guard !mics.isEmpty, !systems.isEmpty else { return [] }
        return mics.compactMap { mic in
            guard isEligible(mic) else { return nil }
            guard let match = systems.first(where: { isMatch(mic: mic, system: $0) }) else {
                return nil
            }
            return (mic.id, match.id)
        }
    }

    /// True iff the segment passes the duration / confidence / non-
    /// empty-text gate that applies to BOTH sides of a candidate pair.
    private static func isEligible(_ segment: Segment) -> Bool {
        guard segment.durationMs >= minSegmentDurationMs else { return false }
        if let conf = segment.confidence, conf < minConfidence { return false }
        return !segment.text.isEmpty
    }

    /// True iff `system` is eligible AND meets both the time-overlap
    /// and text-similarity thresholds against `mic`.
    private static func isMatch(mic: Segment, system: Segment) -> Bool {
        guard isEligible(system) else { return false }
        guard timeOverlapFraction(mic: mic, system: system) >= minOverlapFraction else { return false }
        return jaccardTextSimilarity(mic.text, system.text) >= minTextSimilarity
    }

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
    /// split (Foundation respects unicode general categories).
    static func tokenize(_ text: String) -> Set<String> {
        let lower = text.lowercased()
        let separators = CharacterSet.alphanumerics.inverted
        return Set(
            lower
                .components(separatedBy: separators)
                .filter { !$0.isEmpty }
        )
    }

    private static func loadSegments(meetingID: String, in db: GRDB.Database) throws -> [Segment] {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT id, speaker_id, start_ms, end_ms, text, confidence,
                   (SELECT source FROM speakers WHERE speakers.id = transcript_segments.speaker_id) AS source
            FROM transcript_segments
            WHERE meeting_id = ?
              AND is_final = 1
              AND deduped_against_segment_id IS NULL
            """,
            arguments: [meetingID]
        )
        return rows.compactMap { row -> Segment? in
            guard let id: Int64 = row["id"],
                  let speakerID: Int64 = row["speaker_id"],
                  let source: String = row["source"],
                  let startMs: Int = row["start_ms"],
                  let endMs: Int = row["end_ms"],
                  let text: String = row["text"]
            else { return nil }
            return Segment(
                id: id,
                speakerID: speakerID,
                source: source,
                startMs: startMs,
                endMs: endMs,
                text: text,
                confidence: row["confidence"]
            )
        }
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
