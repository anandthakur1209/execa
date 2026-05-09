import Foundation

/// One row in the live transcript view. Owned by `TranscriptStore` and
/// observed by `LiveMeetingView`. Distinct from `transcript_segments` (the DB
/// row) — `TranscriptLine` is UI state with display labels resolved, while
/// the DB row stores `speaker_id` (FK to `speakers`) and unresolved text.
struct TranscriptLine: Equatable, Identifiable {
    let id: UUID
    /// Resolved display label: "Anand" / "In-room 2" / "Speaker 1". Set at
    /// the time the line was created; rename in Phase 3 will mutate this
    /// across all matching lines.
    var speakerLabel: String
    var text: String
    /// `false` → render in italic + secondary foreground.
    /// `true`  → render in normal weight, committed to the DB.
    var isFinal: Bool
    /// Seconds since `MeetingState.recording(_:startedAt:)` payload.
    var timestamp: TimeInterval
    /// Distinguishes mic vs system in case the UI ever wants to colour-code
    /// or filter; Phase 2 doesn't, but the field is cheap.
    var source: PCMChunk.Source
    /// `transcript_segments.id` once the line has been persisted as a
    /// final. `nil` for interim lines (which haven't hit the DB yet).
    /// Used by Phase 3 commit 8's split context menu — split needs a
    /// segment row ID to point at.
    var databaseSegmentID: Int64?
    /// `speakers.id` of the row this line is attributed to. Set on
    /// every applyInterim/applyFinal so the BUG 7 label-propagation
    /// pass can update `speakerLabel` in-place when the user renames
    /// or merges this speaker. Always set in production (we resolve
    /// the speakers row before pushing to `lines`); optional only for
    /// defensive testing of pre-resolution code paths.
    var databaseSpeakerID: Int64?
}
