import Foundation
import GRDB

/// Single source of truth for speaker-related SELECTs that resolve the
/// `merged_into_speaker_id` alias chain. Avoids scattering
/// `COALESCE(merged.display_label, ...)` SQL across views.
///
/// All helpers run inside the caller's `database.queue.read` /
/// `.write` block so they compose with bulk read/aggregate queries.
enum SpeakerQueries {
    /// Looks up the `display_label` for a single `speakers.id`.
    /// Returns `nil` if the row doesn't exist. Doesn't walk the merge
    /// alias — callers post-merge use `effectiveLabel(...)` for that.
    static func displayLabel(speakerID: Int64, in db: GRDB.Database) throws -> String? {
        try String.fetchOne(
            db,
            sql: "SELECT display_label FROM speakers WHERE id = ?",
            arguments: [speakerID]
        )
    }

    /// Walks the `merged_into_speaker_id` chain from `speakerID` to the
    /// canonical (un-merged) speaker. The merge target itself is
    /// canonical (its `merged_into_speaker_id` should be NULL — if it
    /// isn't, we follow further).
    ///
    /// Phase 3 supports a single hop in practice (the UI merges A → B
    /// only if neither A nor B is already an alias), but we walk
    /// defensively in case a future workflow lets aliases chain.
    /// Bounded loop (max 16 hops) so a self-referencing data
    /// corruption can't hang.
    static func canonicalSpeakerID(_ speakerID: Int64, in db: GRDB.Database) throws -> Int64 {
        var current = speakerID
        for _ in 0 ..< 16 {
            let next: Int64? = try Int64.fetchOne(
                db,
                sql: "SELECT merged_into_speaker_id FROM speakers WHERE id = ?",
                arguments: [current]
            )
            guard let next else { return current }
            if next == current { return current } // self-loop guard
            current = next
        }
        // 16-hop cycle suggests data corruption; return the last id
        // we resolved rather than looping forever.
        return current
    }

    /// Returns the effective display label for `speakerID`,
    /// resolving the merge alias if any. Returns `nil` if the row
    /// doesn't exist.
    static func effectiveLabel(_ speakerID: Int64, in db: GRDB.Database) throws -> String? {
        let canonical = try canonicalSpeakerID(speakerID, in: db)
        return try displayLabel(speakerID: canonical, in: db)
    }

    /// Talk-time per *effective* (post-merge) speaker, in milliseconds.
    /// Aggregates `(end_ms - start_ms)` over all final segments,
    /// grouping by the canonical speaker after walking aliases. Useful
    /// for the speaker sidebar (live + post-meeting) and for the
    /// detail view's per-speaker breakdown. Phase 3.5: filters out
    /// segments soft-deleted by the bleed-through dedup pass so
    /// duplicate-talk-time isn't counted.
    ///
    /// Returns `[canonicalSpeakerID: totalMs]`. Speakers with zero
    /// segments are omitted.
    static func talkTimeAggregated(
        meetingID: String,
        in db: GRDB.Database
    ) throws -> [Int64: Int] {
        // Recursive CTE could resolve arbitrary chains, but Phase 3
        // ships single-hop merges; a LEFT JOIN suffices and is
        // legible. The COALESCE picks the merge target's id when
        // present, otherwise the segment's own speaker_id.
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT
                COALESCE(s.merged_into_speaker_id, s.id) AS effective_id,
                SUM(t.end_ms - t.start_ms) AS total_ms
            FROM transcript_segments t
            JOIN speakers s ON s.id = t.speaker_id
            WHERE t.meeting_id = ?
              AND t.is_final = 1
              AND t.deduped_against_segment_id IS NULL
            GROUP BY effective_id
            """,
            arguments: [meetingID]
        )
        var result: [Int64: Int] = [:]
        for row in rows {
            guard let effectiveID: Int64 = row["effective_id"] else { continue }
            let total: Int = row["total_ms"] ?? 0
            result[effectiveID, default: 0] += max(0, total)
        }
        return result
    }

    /// Lists the canonical (un-merged) speakers for a meeting that
    /// are still visible after the Phase 3.5 dedup pass — i.e. each
    /// returned speaker has at least one final segment whose
    /// `deduped_against_segment_id IS NULL`. Single source of truth
    /// for the orphan-mic-speaker filter; `SpeakerSidebar.derive` and
    /// `MeetingDetailView.loadSpeakerRows` both call this so any
    /// future call site that lists speakers stays in sync.
    ///
    /// Returns rows in `(source, raw_speaker_id)` order with columns:
    /// `id`, `source`, `raw_speaker_id`, `display_label`,
    /// `effective_id` (post-merge canonical id, falls back to `id`
    /// when not merged).
    static func visibleSpeakers(
        meetingID: String,
        in db: GRDB.Database
    ) throws -> [Row] {
        try Row.fetchAll(
            db,
            sql: """
            SELECT s.id AS id,
                   s.source AS source,
                   s.raw_speaker_id AS raw_speaker_id,
                   COALESCE(merged.display_label, s.display_label) AS display_label,
                   COALESCE(s.merged_into_speaker_id, s.id) AS effective_id
            FROM speakers s
            LEFT JOIN speakers merged ON merged.id = s.merged_into_speaker_id
            WHERE s.meeting_id = ?
              AND s.merged_into_speaker_id IS NULL
              AND EXISTS (
                  SELECT 1 FROM transcript_segments t
                  WHERE t.speaker_id = s.id
                    AND t.is_final = 1
                    AND t.deduped_against_segment_id IS NULL
              )
            ORDER BY s.source, s.raw_speaker_id
            """,
            arguments: [meetingID]
        )
    }
}
