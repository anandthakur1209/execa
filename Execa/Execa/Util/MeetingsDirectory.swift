import Foundation

enum MeetingsDirectory {
    static func root() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let url = appSupport
            .appendingPathComponent("com.anandthakur.execa", isDirectory: true)
            .appendingPathComponent("meetings", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func url(forMeetingID meetingID: String) throws -> URL {
        let url = try root().appendingPathComponent(meetingID, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
