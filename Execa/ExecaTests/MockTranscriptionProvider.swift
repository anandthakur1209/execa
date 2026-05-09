@testable import Execa
import Foundation

/// Test double that emits a scripted sequence of `TranscriptionEvent`s
/// without touching the network or a real Sarvam key. Drives
/// `TranscriptStoreTests` and `TranscriptionServiceTests`.
///
/// The audio stream handed to `start(...)` is drained in the background so
/// upstream producers don't fill their buffer; the chunks themselves are
/// counted (`ingestedChunkCount`) but otherwise discarded.
final class MockTranscriptionProvider: TranscriptionProvider, @unchecked Sendable {
    nonisolated let events: AsyncStream<TranscriptionEvent>
    private nonisolated let continuation: AsyncStream<TranscriptionEvent>.Continuation
    /// Per-instance override of the protocol's
    /// `providesAbsoluteTimestamps` requirement. Defaults to `true` so
    /// existing tests that build tokens with non-zero `startMs` keep
    /// working unchanged. The Sarvam-fallback regression test passes
    /// `false` to mimic Sarvam's wire-format constraint.
    nonisolated let providesAbsoluteTimestamps: Bool

    private let lock = NSLock()
    private let scripted: [TranscriptionEvent]
    private let scriptedAfterRetry: [TranscriptionEvent]
    private let interEventDelayNs: UInt64
    private var emitterTask: Task<Void, Never>?
    private var drainTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var chunkCount = 0

    init(
        events: [TranscriptionEvent],
        eventsAfterRetry: [TranscriptionEvent] = [],
        interEventDelayMs: UInt64 = 0,
        providesAbsoluteTimestamps: Bool = true
    ) {
        scripted = events
        scriptedAfterRetry = eventsAfterRetry
        interEventDelayNs = interEventDelayMs * 1_000_000
        self.providesAbsoluteTimestamps = providesAbsoluteTimestamps

        var capturedCont: AsyncStream<TranscriptionEvent>.Continuation?
        let stream = AsyncStream<TranscriptionEvent> { cont in capturedCont = cont }
        self.events = stream
        guard let cont = capturedCont else {
            preconditionFailure("AsyncStream did not yield continuation")
        }
        continuation = cont
    }

    func start(meetingID _: String, source _: PCMChunk.Source, audioStream: AsyncStream<PCMChunk>) async throws {
        // Drain in the background so the producer doesn't stall on a full
        // buffer mid-test.
        let drainCounter = { [weak self] in
            for await _ in audioStream {
                guard let self else { return }
                lock.lock()
                chunkCount += 1
                lock.unlock()
            }
        }
        let drain = Task(operation: drainCounter)

        let scripted = scripted
        let delay = interEventDelayNs
        let cont = continuation
        let emit = Task {
            for event in scripted {
                if Task.isCancelled { return }
                cont.yield(event)
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: delay)
                }
            }
        }

        lock.lock()
        emitterTask = emit
        drainTask = drain
        lock.unlock()
    }

    func stop() async {
        lock.lock()
        let emit = emitterTask
        let drain = drainTask
        let retry = retryTask
        emitterTask = nil
        drainTask = nil
        retryTask = nil
        lock.unlock()
        emit?.cancel()
        drain?.cancel()
        retry?.cancel()
        continuation.finish()
    }

    /// Emits the `eventsAfterRetry` array passed at init, mirroring
    /// `SarvamProvider.retry()`'s "more events flow through the same
    /// stream" semantic without needing an actual reconnect loop.
    func retry() async {
        let toEmit = scriptedAfterRetry
        guard !toEmit.isEmpty else { return }
        let cont = continuation
        let delay = interEventDelayNs
        let task = Task {
            for event in toEmit {
                if Task.isCancelled { return }
                cont.yield(event)
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: delay)
                }
            }
        }
        lock.lock()
        retryTask = task
        lock.unlock()
    }

    /// Number of `PCMChunk`s pushed into the audio stream. Useful for
    /// verifying that a test producer ran to completion.
    func ingestedChunkCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return chunkCount
    }
}
