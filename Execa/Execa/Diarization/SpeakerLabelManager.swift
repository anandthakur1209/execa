import Foundation
import GRDB

/// DB-write actor for speaker management operations: rename, merge,
/// split. Phase 3 commit 1 ships only `rename`; `merge` and `split`
/// land in commit 5 once `SpeakerQueries` is fleshed out.
///
/// All three operations are async DB writes through GRDB's
/// `DatabaseQueue`, which serialises writes — so a mid-meeting rename
/// from `SpeakerSidebar` running concurrently with streaming
/// `transcript_segments` inserts from `TranscriptStore` is safe. UI
/// re-renders via `@Observable` invalidation on `TranscriptStore`
/// (live) or fresh DB queries (post-meeting in `MeetingDetailView`).
///
/// `display_label` updates ripple to all current and future
/// `transcript_segments` automatically because rendering joins
/// `speakers` rather than denormalising the label onto segment rows
/// (per Phase 1's data-model decision and the BUG-6-era fix that the
/// `(meeting_id, source, raw_speaker_id)` tuple is the stable key).
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
}

enum SpeakerLabelManagerError: Error, Equatable {
    case emptyLabel
    case speakerNotFound
    case segmentNotFound
    case mergeIntoSelf
}
