import AVFoundation
import Foundation
import GRDB

actor AudioCaptureService {
    private let mic: AudioSource
    private let system: AudioSource
    private let permissions: PermissionsService
    private let database: Database

    /// State transitions are emitted to subscribers as soon as they happen.
    /// The menu bar binds its label and items off this stream.
    ///
    /// **Single-consumer contract.** AsyncStream events are split between
    /// concurrent iterators (whichever pulls first wins each event); two
    /// `for await` loops on this stream produce a hard-to-debug deadlock
    /// where one consumer routinely misses `.idle` and the menu bar gets
    /// stuck on "Saving meeting…". The Phase 2 manual smoke surfaced
    /// exactly that bug — `ExecaApp.observeMeetingState(_:)` is the sole
    /// iterator; child views (LiveMeetingView, etc.) receive the current
    /// `MeetingState` as a parameter from ExecaApp's `@State`. The
    /// `#if DEBUG` getter guard below trips on a second iterator
    /// creation.
    private nonisolated let _stateStream: AsyncStream<MeetingState>
    private nonisolated let stateContinuation: AsyncStream<MeetingState>.Continuation

    nonisolated var stateStream: AsyncStream<MeetingState> {
        #if DEBUG
        // Bumps on every property read, not every iterator creation —
        // good enough for the current codebase (one read in
        // `ExecaApp.observeMeetingState`). If a future change introduces
        // a non-iterating read of this property and starts tripping a
        // false positive, move the counter into a wrapping
        // `AsyncSequence` that bumps inside `makeAsyncIterator()` —
        // more code, fewer false positives.
        stateStreamReadGuard.lock()
        stateStreamReadCount += 1
        let count = stateStreamReadCount
        stateStreamReadGuard.unlock()
        assert(count == 1, """
        AudioCaptureService.stateStream is single-consumer. A second \
        read was made (likely a second `for await` iterator) — pass \
        `meetingState` from ExecaApp down to child views instead of \
        opening another for-await loop. See Phase 2 manual-smoke fix \
        for BUG 1.
        """)
        #endif
        return _stateStream
    }

    #if DEBUG
    private nonisolated let stateStreamReadGuard = NSLock()
    private nonisolated(unsafe) var stateStreamReadCount = 0
    #endif

    private(set) var state: MeetingState = .idle {
        didSet {
            stateContinuation.yield(state)
        }
    }

    private var currentMeetingID: String?
    private var currentDirectory: URL?
    private var errorObservationTask: Task<Void, Never>?

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
        var capturedContinuation: AsyncStream<MeetingState>.Continuation?
        let stream = AsyncStream<MeetingState>(bufferingPolicy: .bufferingNewest(8)) { cont in
            capturedContinuation = cont
        }
        _stateStream = stream
        guard let continuation = capturedContinuation else {
            preconditionFailure("AsyncStream did not yield continuation")
        }
        stateContinuation = continuation
        // Seed subscribers with the initial idle state so the menu bar can
        // render immediately on first observe.
        continuation.yield(.idle)
    }

    /// Nonisolated accessors exposed for `TranscriptionService` to subscribe
    /// without crossing the actor boundary. The underlying `AudioSource`
    /// streams are themselves nonisolated.
    nonisolated var micSttStream: AsyncStream<PCMChunk> {
        mic.sttStream
    }

    nonisolated var systemSttStream: AsyncStream<PCMChunk> {
        system.sttStream
    }

    /// Used by AppCoordinator's preflight gate (Phase 2 missing-key check)
    /// to surface an error state without going through the regular start
    /// path. The menu bar's existing `.error(...)` rendering picks this up
    /// via `stateStream`.
    func recordPreflightError(_ error: MeetingError) {
        state = .error(error)
    }

    /// Clears a preflight error and returns the state machine to `.idle`.
    /// Wired to the menu bar's "Dismiss" button so the user can leave
    /// the error state without quitting the app. No-op if not currently
    /// in an error state — protects an in-progress meeting from being
    /// silently aborted by a misrouted Dismiss click.
    func clearError() {
        if case .error = state {
            state = .idle
        }
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
        startErrorObservation()
        return directory
    }

    private func startErrorObservation() {
        errorObservationTask?.cancel()
        let mic = mic
        let system = system
        errorObservationTask = Task { [weak self] in
            await withTaskGroup(of: MeetingError?.self) { group in
                group.addTask { for await err in mic.errorStream {
                    return err
                }; return nil }
                group.addTask { for await err in system.errorStream {
                    return err
                }; return nil }
                if let firstError = await group.next(), let firstError {
                    group.cancelAll()
                    await self?.handleSourceError(firstError)
                }
            }
        }
    }

    private func handleSourceError(_ error: MeetingError) async {
        guard case let .recording(meetingID, _) = state else { return }
        // Stop both sources cleanly so partially-written .wavs remain valid.
        await mic.stop()
        await system.stop()
        try? await markFailedRow(meetingID: meetingID)
        currentMeetingID = nil
        currentDirectory = nil
        state = .error(error)
    }

    @discardableResult
    func stop() async throws -> URL? {
        guard case let .recording(meetingID, _) = state, let directory = currentDirectory else {
            return nil
        }
        errorObservationTask?.cancel()
        errorObservationTask = nil
        state = .stopping

        await mic.stop()
        await system.stop()

        // .savingMeeting covers the FLAC-encoding window so the menu bar can
        // show "Saving..." while AudioMixer runs (multi-second on a 1-hour
        // meeting). The stop path swallows mixer errors — partial .wav files
        // remain on disk so the meeting can be re-mixed later.
        state = .savingMeeting(meetingID: meetingID)

        let micURL = directory.appendingPathComponent("mic.wav")
        let systemURL = directory.appendingPathComponent("system.wav")
        let masterURL = directory.appendingPathComponent("master.flac")
        do {
            try AudioMixer.writeMasterFLAC(micWAV: micURL, systemWAV: systemURL, output: masterURL)
        } catch {
            // Logged via the row failing-soft path; the partial wavs remain
            // valid for re-processing.
        }

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
