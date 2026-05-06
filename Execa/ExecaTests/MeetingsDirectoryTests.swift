@testable import Execa
import Foundation
import Testing

struct MeetingsDirectoryTests {
    @Test func rootIsUnderSandboxAppSupport() throws {
        let root = try MeetingsDirectory.root()
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        #expect(root.path.hasPrefix(appSupport.path))
        #expect(root.lastPathComponent == "meetings")
        #expect(FileManager.default.fileExists(atPath: root.path))
    }

    @Test func meetingDirectoryIsCreatedAndIdempotent() throws {
        let id = ULID.generate()
        let first = try MeetingsDirectory.url(forMeetingID: id)
        let second = try MeetingsDirectory.url(forMeetingID: id)
        #expect(first == second)
        #expect(FileManager.default.fileExists(atPath: first.path))
        try FileManager.default.removeItem(at: first)
    }
}
