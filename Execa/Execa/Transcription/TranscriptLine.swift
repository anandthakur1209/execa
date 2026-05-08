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
}
