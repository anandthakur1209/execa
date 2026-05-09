import Foundation
import GRDB

/// Single source of truth for speaker-related SELECTs that resolve the
/// `merged_into_speaker_id` alias chain. Avoids scattering
/// `COALESCE(merged.display_label, ...)` SQL across views.
///
/// Phase 3 commit 1 lands only the simple cases (used by tests + the
/// rename path). The merge-alias-resolving helpers
/// (`canonicalSpeakerID`, `effectiveLabel`, `talkTimeAggregated`) land
/// in commit 5 alongside `SpeakerLabelManager.merge`/`split`, when
/// there's something for them to resolve against.
enum SpeakerQueries {
    /// Looks up the `display_label` for a single `speakers.id`.
    /// Returns `nil` if the row doesn't exist. Doesn't walk the merge
    /// alias — callers post-merge use `effectiveLabel(...)` (commit 5)
    /// to follow `merged_into_speaker_id`.
    static func displayLabel(speakerID: Int64, in db: GRDB.Database) throws -> String? {
        try String.fetchOne(
            db,
            sql: "SELECT display_label FROM speakers WHERE id = ?",
            arguments: [speakerID]
        )
    }
}
