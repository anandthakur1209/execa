@testable import Execa
import Foundation

/// Test double for AudioSource that drives AudioCaptureServiceTests without
/// real CoreAudio / ScreenCaptureKit. Tracks start/stop calls and can throw
/// on start to exercise the source-startup atomicity contract.
actor StubAudioSource: AudioSource {
    nonisolated let sttStream: AsyncStream<PCMChunk>
    private nonisolated let continuation: AsyncStream<PCMChunk>.Continuation
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
        sttStream = stream
        guard let sttCaptured = sttCont else {
            preconditionFailure("AsyncStream did not yield continuation")
        }
        continuation = sttCaptured

        var errCont: AsyncStream<MeetingError>.Continuation?
        let errStream = AsyncStream<MeetingError> { cont in errCont = cont }
        errorStream = errStream
        guard let errCaptured = errCont else {
            preconditionFailure("AsyncStream did not yield continuation")
        }
        errorContinuation = errCaptured
    }

    /// Test-only hook to simulate a write error reaching the source.
    nonisolated func emitError(_ error: MeetingError) {
        errorContinuation.yield(error)
    }

    func start(archivalURL: URL) async throws {
        startedURL = archivalURL
        if shouldThrowOnStart {
            throw MeetingError.streamFailed("stub start failure")
        }
        didStart = true
    }

    func stop() async {
        didStop = true
        continuation.finish()
        errorContinuation.finish()
    }
}
