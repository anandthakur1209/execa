import AVFoundation
import Foundation
import GRDB

actor AudioCaptureService {
    private let mic: AudioSource
    private let system: AudioSource
    private let permissions: PermissionsService
    private let database: Database

    private(set) var state: MeetingState = .idle
    private var currentMeetingID: String?
    private var currentDirectory: URL?

    init(
        mic: AudioSource,
        system: AudioSource,
        permissions: PermissionsService,
        database: Database
    ) {
        self.mic = mic
        self.system = system
        self.permissions = permissions
        self.database = database
    }

    @discardableResult
    func start(meetingID: String) async throws -> URL {
        guard case .idle = state else {
            throw MeetingError.streamFailed("AudioCaptureService is not idle (state=\(state))")
        }
        state = .starting

        // Permission gate. Must run before any source is touched so the menu
        // bar can deep-link the user to System Settings without leaving a
        // half-started recording behind.
        let micStatus = await permissions.microphoneStatus()
        if micStatus != .authorized {
            state = .error(.permissionDenied(.microphone))
            throw MeetingError.permissionDenied(.microphone)
        }
        if !permissions.screenRecordingStatus() {
            state = .error(.permissionDenied(.screenRecording))
            throw MeetingError.permissionDenied(.screenRecording)
        }

        let directory: URL
        do {
            directory = try MeetingsDirectory.url(forMeetingID: meetingID)
        } catch {
            state = .error(.streamFailed("could not create meeting directory: \(error)"))
            throw error
        }
        let micURL = directory.appendingPathComponent("mic.wav")
        let systemURL = directory.appendingPathComponent("system.wav")

        let startedAt = Date()
        try await insertLiveRow(meetingID: meetingID, startedAt: startedAt)
        currentMeetingID = meetingID
        currentDirectory = directory

        do {
            try await startSources(micURL: micURL, systemURL: systemURL)
        } catch {
            // Source-startup atomicity: stop whichever source did start, mark
            // the row failed, and rethrow the original error unchanged.
            await mic.stop()
            await system.stop()
            try? await markFailedRow(meetingID: meetingID)
            currentMeetingID = nil
            currentDirectory = nil
            state = .error(meetingError(from: error))
            throw error
        }

        state = .recording(meetingID: meetingID, startedAt: startedAt)
        return directory
    }

    @discardableResult
    func stop() async throws -> URL? {
        guard case let .recording(meetingID, _) = state, let directory = currentDirectory else {
            return nil
        }
        state = .stopping

        await mic.stop()
        await system.stop()

        // .savingMeeting covers the FLAC-encoding window. Phase 5's mixer call
        // lands here; for now we transition through the state so the menu bar
        // can show "Saving..." and tests can observe the lifecycle.
        state = .savingMeeting(meetingID: meetingID)

        // FLAC encoding is wired in the next commit (AudioMixer).

        let endedAt = Date()
        let audioPath = "meetings/\(meetingID)"
        try? await markEndedRow(meetingID: meetingID, endedAt: endedAt, audioPath: audioPath)

        currentMeetingID = nil
        currentDirectory = nil
        state = .idle
        return directory
    }

    private func startSources(micURL: URL, systemURL: URL) async throws {
        async let micStart: Void = mic.start(archivalURL: micURL)
        async let systemStart: Void = system.start(archivalURL: systemURL)

        var micError: Error?
        var systemError: Error?
        do { try await micStart } catch { micError = error }
        do { try await systemStart } catch { systemError = error }

        if let micError {
            throw micError
        }
        if let systemError {
            throw systemError
        }
    }

    private func insertLiveRow(meetingID: String, startedAt: Date) async throws {
        try await database.queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO meetings (id, title, started_at, status)
                    VALUES (?, ?, ?, ?)
                """,
                arguments: [
                    meetingID,
                    nil,
                    Int64(startedAt.timeIntervalSince1970 * 1000),
                    "live"
                ]
            )
        }
    }

    private func markEndedRow(meetingID: String, endedAt: Date, audioPath: String) async throws {
        try await database.queue.write { db in
            try db.execute(
                sql: """
                    UPDATE meetings SET status = ?, ended_at = ?, audio_path = ? WHERE id = ?
                """,
                arguments: [
                    "ended",
                    Int64(endedAt.timeIntervalSince1970 * 1000),
                    audioPath,
                    meetingID
                ]
            )
        }
    }

    private func markFailedRow(meetingID: String) async throws {
        try await database.queue.write { db in
            try db.execute(
                sql: "UPDATE meetings SET status = ? WHERE id = ?",
                arguments: ["failed", meetingID]
            )
        }
    }

    private func meetingError(from error: Error) -> MeetingError {
        if let meetingError = error as? MeetingError { return meetingError }
        return .streamFailed(String(describing: error))
    }
}
