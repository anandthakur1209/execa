import AVFoundation
@testable import Execa
import Foundation
import GRDB
import Testing

struct AudioCaptureServiceTests {
    private static func tempDB() throws -> Execa.Database {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("execa-acs-\(UUID().uuidString).sqlite3")
        return try Execa.Database.make(at: url)
    }

    private static func meetingsRow(_ database: Execa.Database,
                                    id: String) async throws -> (status: String, endedAt: Int64?)? {
        try await database.queue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT status, ended_at FROM meetings WHERE id = ?",
                arguments: [id]
            )
            guard let row else { return nil }
            return (row["status"], row["ended_at"])
        }
    }

    /// Force-grants both permissions on a stub so we can drive the orchestrator
    /// in unit tests without needing real TCC consent.
    actor StubPermissions {
        let mic: AVAuthorizationStatus
        let screen: Bool
        init(mic: AVAuthorizationStatus = .authorized, screen: Bool = true) {
            self.mic = mic
            self.screen = screen
        }
    }

    @Test func startStopHappyPath() async throws {
        let db = try Self.tempDB()
        let permissions = PermissionsService()
        // PermissionsService talks to TCC, which the test host typically has
        // already granted (or not). Skip if not — same gating pattern as the
        // real-source tests. Without permission the orchestrator throws
        // permissionDenied; that's the next test below.
        guard await permissions.microphoneStatus() == .authorized,
              permissions.screenRecordingStatus()
        else { return }

        let mic = StubAudioSource()
        let system = StubAudioSource()
        let service = AudioCaptureService(mic: mic, system: system, permissions: permissions, database: db)
        let meetingID = ULID.generate()

        let directory = try await service.start(meetingID: meetingID)
        #expect(FileManager.default.fileExists(atPath: directory.path))
        #expect(await mic.didStart)
        #expect(await system.didStart)

        let liveRow = try await Self.meetingsRow(db, id: meetingID)
        #expect(liveRow?.status == "live")

        _ = try await service.stop()
        #expect(await mic.didStop)
        #expect(await system.didStop)

        let endedRow = try await Self.meetingsRow(db, id: meetingID)
        #expect(endedRow?.status == "ended")
        #expect(endedRow?.endedAt != nil)

        try? FileManager.default.removeItem(at: directory)
    }

    @Test func sourceStartupAtomicityMarksRowFailed() async throws {
        let db = try Self.tempDB()
        let permissions = PermissionsService()
        guard await permissions.microphoneStatus() == .authorized,
              permissions.screenRecordingStatus()
        else { return }

        let mic = StubAudioSource()
        let system = StubAudioSource(shouldThrowOnStart: true)
        let service = AudioCaptureService(mic: mic, system: system, permissions: permissions, database: db)
        let meetingID = ULID.generate()

        await #expect(throws: (any Error).self) {
            try await service.start(meetingID: meetingID)
        }

        // Atomicity: the source that did succeed must be told to stop, and the
        // partially-inserted row must transition to status='failed'.
        #expect(await mic.didStop)
        #expect(await system.didStop)
        let row = try await Self.meetingsRow(db, id: meetingID)
        #expect(row?.status == "failed")
    }

    @Test func diskFullErrorTransitionsState() async throws {
        let db = try Self.tempDB()
        let permissions = PermissionsService()
        guard await permissions.microphoneStatus() == .authorized,
              permissions.screenRecordingStatus()
        else { return }

        let mic = StubAudioSource()
        let system = StubAudioSource()
        let service = AudioCaptureService(mic: mic, system: system, permissions: permissions, database: db)
        let meetingID = ULID.generate()

        let directory = try await service.start(meetingID: meetingID)
        defer { try? FileManager.default.removeItem(at: directory) }

        mic.emitError(.diskFull)

        // Allow the observation task to drain.
        for _ in 0 ..< 20 {
            if case .error(.diskFull) = await service.state { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        if case .error(.diskFull) = await service.state {
            // ok
        } else {
            await Issue.record("expected service.state to transition to .error(.diskFull); got \(service.state)")
        }

        let row = try await Self.meetingsRow(db, id: meetingID)
        #expect(row?.status == "failed")
    }

    @Test func emptyMeetingDoesNotCrash() async throws {
        let db = try Self.tempDB()
        let permissions = PermissionsService()
        guard await permissions.microphoneStatus() == .authorized,
              permissions.screenRecordingStatus()
        else { return }

        let mic = StubAudioSource()
        let system = StubAudioSource()
        let service = AudioCaptureService(mic: mic, system: system, permissions: permissions, database: db)
        let meetingID = ULID.generate()

        let directory = try await service.start(meetingID: meetingID)
        let stopped = try await service.stop()
        #expect(stopped == directory)
        let row = try await Self.meetingsRow(db, id: meetingID)
        #expect(row?.status == "ended")

        try? FileManager.default.removeItem(at: directory)
    }
}
