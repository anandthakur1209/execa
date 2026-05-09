import Foundation

/// Per-meeting diarization-pipeline state, mirrored to the
/// `meetings.diarization_status` column added in v3 of the DB schema.
///
/// State machine:
///
///     .notRequested    →    .pending    →    .completed(at:)
///                                       ↘     .failed(message:)
///
/// `.notRequested` is the initial state — either no batch fire has been
/// attempted yet, or the `auto_diarization` setting was off when the
/// meeting ended. `DiarizationService.runForMeeting(...)` transitions
/// through `.pending` while batch calls are in flight, and lands on
/// `.completed` (with a timestamp the UI can show "diarized N seconds
/// ago" against) or `.failed` (with the user-facing error message
/// surfaced in `MeetingDetailView`'s status pill).
enum DiarizationStatus: Equatable {
    case notRequested
    case pending
    case completed(at: Date)
    case failed(message: String)
}
