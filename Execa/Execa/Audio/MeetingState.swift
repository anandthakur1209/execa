import Foundation

enum MeetingError: Error, Equatable {
    enum Permission: String, Equatable {
        case microphone
        case screenRecording
    }

    case permissionDenied(Permission)
    case diskFull
    case streamFailed(String)
}

enum MeetingState: Equatable {
    case idle
    case starting
    case recording(meetingID: String, startedAt: Date)
    case stopping
    case savingMeeting(meetingID: String)
    case error(MeetingError)
}
