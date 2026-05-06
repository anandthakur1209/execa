@testable import Execa
import Foundation

/// Test double for AudioSource that drives AudioCaptureServiceTests without
/// real CoreAudio / ScreenCaptureKit. Tracks start/stop calls and can throw
/// on start to exercise the source-startup atomicity contract.
actor StubAudioSource: AudioSource {
    nonisolated let sttStream: AsyncStream<PCMChunk>
    private nonisolated let continuation: AsyncStream<PCMChunk>.Continuation

    let shouldThrowOnStart: Bool
    private(set) var didStart = false
    private(set) var didStop = false
    private(set) var startedURL: URL?

    init(shouldThrowOnStart: Bool = false) {
        self.shouldThrowOnStart = shouldThrowOnStart
        var captured: AsyncStream<PCMChunk>.Continuation?
        let stream = AsyncStream<PCMChunk> { cont in captured = cont }
        sttStream = stream
        guard let cont = captured else {
            preconditionFailure("AsyncStream did not yield continuation")
        }
        continuation = cont
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
    }
}
