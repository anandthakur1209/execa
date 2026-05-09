import Foundation
import GRDB

/// DB-write actor for speaker management operations: rename, merge,
/// split. All three operations are async DB writes through GRDB's
/// `DatabaseQueue`, which serialises writes — so a mid-meeting rename
/// from `SpeakerSidebar` running concurrently with streaming
/// `transcript_segments` inserts from `TranscriptStore` is safe. UI
/// re-renders via `@Observable` invalidation on `TranscriptStore`
/// (live) or fresh DB queries (post-meeting in `MeetingDetailView`).
///
/// `display_label` updates ripple to all current and future
/// `transcript_segments` automatically because rendering joins
/// `speakers` rather than denormalising the label onto segment rows
/// (Phase 1 data-model + the `(meeting_id, source, raw_speaker_id)`
/// stable-key contract).
actor SpeakerLabelManager {
    private let database: Database

    init(database: Database) {
        self.database = database
    }

    /// Renames a single `speakers` row. Empty-string labels are
    /// rejected — the UI's `TextField` should also reject them up
    /// front, but we defend in depth.
    func rename(speakerID: Int64, to newLabel: String) async throws {
        let trimmed = newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SpeakerLabelManagerError.emptyLabel
        }
        try await database.queue.write { db in
            try db.execute(
                sql: "UPDATE speakers SET display_label = ? WHERE id = ?",
                arguments: [trimmed, speakerID]
            )
        }
    }

    /// Merges `sourceSpeakerID` into `intoTargetSpeakerID` by setting
    /// the source's `merged_into_speaker_id` FK to the target's id.
    /// Cross-source merges (mic→system, system→mic) are supported —
    /// speaker bleed-through (Phase 1 closeout, Decision 5 Path B)
    /// genuinely produces the same person on both streams, and the
    /// user needs to collapse them into one display label.
    ///
    /// Idempotent: re-merging an already-merged source is a no-op.
    /// Existing `transcript_segments` rows attached to the source
    /// speaker stay attached — the merge changes the *display* chain
    /// only, not the segment-to-speaker FK. This avoids row-update
    /// churn on long meetings; `SpeakerQueries.effectiveLabel(...)`
    /// resolves the alias for rendering.
    ///
    /// Errors:
    ///   - `mergeIntoSelf` if source == target.
    ///   - `speakerNotFound` if either id doesn't resolve to a row.
    ///   - propagates GRDB errors otherwise.
    func merge(sourceSpeakerID: Int64, intoTargetSpeakerID targetSpeakerID: Int64) async throws {
        guard sourceSpeakerID != targetSpeakerID else {
            throw SpeakerLabelManagerError.mergeIntoSelf
        }
        try await database.queue.write { db in
            // Existence check + same-meeting check. Cross-meeting
            // merges aren't a feature — phase 3 only supports merging
            // speakers within one meeting.
            let sourceMeeting: String? = try String.fetchOne(
                db,
                sql: "SELECT meeting_id FROM speakers WHERE id = ?",
                arguments: [sourceSpeakerID]
            )
            let targetMeeting: String? = try String.fetchOne(
                db,
                sql: "SELECT meeting_id FROM speakers WHERE id = ?",
                arguments: [targetSpeakerID]
            )
            guard let sourceMeeting, let targetMeeting else {
                throw SpeakerLabelManagerError.speakerNotFound
            }
            guard sourceMeeting == targetMeeting else {
                throw SpeakerLabelManagerError.speakerNotFound
            }
            try db.execute(
                sql: """
                UPDATE speakers
                SET merged_into_speaker_id = ?
                WHERE id = ?
                """,
                arguments: [targetSpeakerID, sourceSpeakerID]
            )
        }
    }

    /// Splits one `transcript_segments` row off into a freshly-created
    /// `speakers` row with `intoNewLabel`. The new speaker uses
    /// `max(existing raw_speaker_id) + 1` for the segment's source so
    /// it doesn't collide with the existing batch-derived clusters.
    /// Returns the new `speakers.id`.
    ///
    /// Single-segment scope (Phase 3 Decision 4): bulk range-split
    /// is deferred. The user right-clicks one transcript turn at a
    /// time. Sibling segments stay attributed to the original
    /// speaker.
    ///
    /// Errors: `segmentNotFound`, `emptyLabel`, propagates GRDB errors.
    @discardableResult
    func split(segmentID: Int64, intoNewLabel newLabel: String) async throws -> Int64 {
        let trimmed = newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SpeakerLabelManagerError.emptyLabel
        }
        return try await database.queue.write { db in
            // Resolve the target segment's meeting + source via its
            // current speaker row.
            let row = try Row.fetchOne(
                db,
                sql: """
                SELECT s.meeting_id AS meeting_id, s.source AS source
                FROM transcript_segments t
                JOIN speakers s ON s.id = t.speaker_id
                WHERE t.id = ?
                """,
                arguments: [segmentID]
            )
            guard let row,
                  let meetingID: String = row["meeting_id"],
                  let source: String = row["source"]
            else {
                throw SpeakerLabelManagerError.segmentNotFound
            }
            let nextRawID: Int = try (Int.fetchOne(
                db,
                sql: """
                SELECT MAX(raw_speaker_id) FROM speakers
                WHERE meeting_id = ? AND source = ?
                """,
                arguments: [meetingID, source]
            ) ?? -1) + 1
            try db.execute(
                sql: """
                INSERT INTO speakers
                    (meeting_id, source, raw_speaker_id, display_label)
                VALUES (?, ?, ?, ?)
                """,
                arguments: [meetingID, source, nextRawID, trimmed]
            )
            let newSpeakerID = db.lastInsertedRowID
            try db.execute(
                sql: "UPDATE transcript_segments SET speaker_id = ? WHERE id = ?",
                arguments: [newSpeakerID, segmentID]
            )
            return newSpeakerID
        }
    }
}

enum SpeakerLabelManagerError: Error, Equatable {
    case emptyLabel
    case speakerNotFound
    case segmentNotFound
    case mergeIntoSelf
}
