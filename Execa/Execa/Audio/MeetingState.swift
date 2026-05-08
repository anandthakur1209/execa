import Foundation

enum MeetingError: Error, Equatable {
    enum Permission: String, Equatable {
        case microphone
        case screenRecording
    }

    case permissionDenied(Permission)
    case diskFull
    case streamFailed(String)
    /// No Sarvam API key in Keychain at meeting-start. Emitted by
    /// `AppCoordinator.startMeeting()`'s preflight gate before any audio
    /// source or transcription provider is touched. The menu bar surfaces
    /// this as a red-triangle icon with an "Add Sarvam key…" deep-link
    /// into the wizard's STT step.
    case missingSTTKey
}

enum MeetingState: Equatable {
    case idle
    case starting
    case recording(meetingID: String, startedAt: Date)
    case stopping
    case savingMeeting(meetingID: String)
    case error(MeetingError)
}
