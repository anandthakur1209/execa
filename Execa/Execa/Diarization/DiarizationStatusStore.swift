import Foundation

/// `@MainActor @Observable` store that publishes per-meeting
/// `DiarizationStatus` values to SwiftUI. Mirrors the Phase 2 split
/// between work-doing actors and SwiftUI-observable stores
/// (`TranscriptionService` actor + `TranscriptStore` MainActor pair):
/// `DiarizationService` does the actual network I/O off-main and posts
/// state transitions here via `update(meetingID:status:)`. Views read
/// `statusByMeeting` synchronously on MainActor, with SwiftUI
/// invalidation handled by `@Observable`.
///
/// Single source of truth for in-memory diarization state across the
/// app. The DB also stores the latest status per meeting for
/// across-launch persistence; on launch, `AppCoordinator` hydrates this
/// store from the `meetings` table so `MeetingDetailView` opened from
/// the "Open last meeting" menu item shows the right pill state.
@MainActor
@Observable
final class DiarizationStatusStore {
    private(set) var statusByMeeting: [String: DiarizationStatus] = [:]

    nonisolated init() {}

    /// Updates the in-memory state for a single meeting. Callers also
    /// persist to `meetings.diarization_status` separately
    /// (`DiarizationService` handles the DB write inline with the
    /// status transition).
    func update(meetingID: String, status: DiarizationStatus) {
        statusByMeeting[meetingID] = status
    }

    func status(forMeetingID meetingID: String) -> DiarizationStatus {
        statusByMeeting[meetingID] ?? .notRequested
    }
}
