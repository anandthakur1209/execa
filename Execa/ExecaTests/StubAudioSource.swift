@testable import Execa
import Foundation

/// Test double for AudioSource that drives AudioCaptureServiceTests without
/// real CoreAudio / ScreenCaptureKit. Tracks start/stop calls and can throw
/// on start to exercise the source-startup atomicity contract.
///
/// Mirrors the production sources' per-meeting `sttStream` recreation: each
/// `start(archivalURL:)` finishes the previous continuation and creates a
/// fresh `(AsyncStream, Continuation)` pair, so the consumer-side code
/// (TranscriptionService bridge tasks) gets a working stream every time.
/// The back-to-back-meetings regression test
/// (`TranscriptionServiceTests.backToBackMeetingsBothTranscribe`) gates this
/// invariant.
actor StubAudioSource: AudioSource {
    private nonisolated(unsafe) var _sttStream: AsyncStream<PCMChunk>
    private nonisolated(unsafe) var sttContinuation: AsyncStream<PCMChunk>.Continuation
    private nonisolated let streamLock = NSLock()

    nonisolated let errorStream: AsyncStream<MeetingError>
    private nonisolated let errorContinuation: AsyncStream<MeetingError>.Continuation

    let shouldThrowOnStart: Bool
    private(set) var didStart = false
    private(set) var didStop = false
    private(set) var startedURL: URL?

    init(shouldThrowOnStart: Bool = false) {
        self.shouldThrowOnStart = shouldThrowOnStart

        var sttCont: AsyncStream<PCMChunk>.Continuation?
        let stream = AsyncStream<PCMChunk> { cont in sttCont = cont }
        _sttStream = stream
        guard let sttCaptured = sttCont else {
            preconditionFailure("AsyncStream did not yield continuation")
        }
        sttContinuation = sttCaptured

        var errCont: AsyncStream<MeetingError>.Continuation?
        let errStream = AsyncStream<MeetingError> { cont in errCont = cont }
        errorStream = errStream
        guard let errCaptured = errCont else {
            preconditionFailure("AsyncStream did not yield continuation")
        }
        errorContinuation = errCaptured
    }

    /// Returns the AsyncStream tied to the most recent `start(...)` call.
    /// Each meeting gets a fresh stream/continuation pair; consumers
    /// (`AudioCaptureService.micSttStream`) are expected to read this
    /// AFTER `start(...)` returns so they pick up the per-meeting
    /// instance.
    nonisolated var sttStream: AsyncStream<PCMChunk> {
        streamLock.lock()
        defer { streamLock.unlock() }
        return _sttStream
    }

    /// Test-only hook to simulate a write error reaching the source.
    nonisolated func emitError(_ error: MeetingError) {
        errorContinuation.yield(error)
    }

    /// Test-only hook to push a synthetic `PCMChunk` into the stub's
    /// current STT stream, simulating a tap-callback fire. Yields to
    /// the *current* continuation (per-meeting), not a captured-once
    /// reference.
    nonisolated func emit(_ chunk: PCMChunk) {
        streamLock.lock()
        let cont = sttContinuation
        streamLock.unlock()
        cont.yield(chunk)
    }

    func start(archivalURL: URL) async throws {
        startedURL = archivalURL
        if shouldThrowOnStart {
            throw MeetingError.streamFailed("stub start failure")
        }
        didStart = true

        // Recreate the (stream, continuation) pair for this meeting.
        // Closes the previous continuation (signals any leftover
        // consumer's for-await to exit cleanly) and points the stub
        // at a fresh pair.
        var newCont: AsyncStream<PCMChunk>.Continuation?
        let newStream = AsyncStream<PCMChunk> { cont in newCont = cont }
        guard let captured = newCont else {
            preconditionFailure("AsyncStream did not yield continuation")
        }
        streamLock.lock()
        sttContinuation.finish()
        _sttStream = newStream
        sttContinuation = captured
        streamLock.unlock()
    }

    func stop() async {
        didStop = true
        streamLock.lock()
        sttContinuation.finish()
        streamLock.unlock()
        // errorContinuation is shared across meetings (same as production
        // sources) — disk-full / stream-failed signals span the lifetime
        // of the source, not a single meeting.
    }
}
