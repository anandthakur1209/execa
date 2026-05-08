import Foundation

/// Owns provider lifecycle for one meeting at a time and bridges provider
/// events into `TranscriptStore`. AppCoordinator constructs one of these
/// at app launch and calls `start(...)` per meeting.
///
/// AudioCaptureService stays focused on audio capture; TranscriptionService
/// is the seam between captured audio and the STT pipeline. The key gate
/// (missing Sarvam key → `MeetingError.missingSTTKey`) is run by
/// AppCoordinator *before* this service is asked to start, so by the time
/// `start(...)` runs we already have a non-empty key bound inside the
/// `providerFactory` closure.
actor TranscriptionService {
    typealias ProviderFactory = @Sendable (PCMChunk.Source) -> any TranscriptionProvider

    /// Bundle of per-meeting parameters passed at start. Keeps the
    /// `start(...)` signature under SwiftLint's parameter-count limit.
    struct StartContext {
        let meetingID: String
        let startedAt: Date
        let displayName: String?
        let micStream: AsyncStream<PCMChunk>
        let systemStream: AsyncStream<PCMChunk>
    }

    private let store: TranscriptStore
    private var micProvider: (any TranscriptionProvider)?
    private var systemProvider: (any TranscriptionProvider)?
    private var bridgeTasks: [Task<Void, Never>] = []

    init(store: TranscriptStore) {
        self.store = store
    }

    /// Starts both providers and bridges their events into `store`. The
    /// caller is responsible for having validated any required credentials
    /// (Sarvam API key) and bound them inside `providerFactory` before this
    /// is called.
    func start(providerFactory: ProviderFactory, context: StartContext) async throws {
        // Initialize the store for this meeting on MainActor.
        let storeRef = store
        await MainActor.run {
            storeRef.beginMeeting(
                meetingID: context.meetingID,
                startedAt: context.startedAt,
                displayName: context.displayName
            )
        }

        let mic = providerFactory(.mic)
        let system = providerFactory(.system)
        do {
            try await mic.start(meetingID: context.meetingID, source: .mic, audioStream: context.micStream)
            try await system.start(
                meetingID: context.meetingID,
                source: .system,
                audioStream: context.systemStream
            )
        } catch {
            // Source-startup atomicity: stop whichever provider did start
            // and rethrow.
            await mic.stop()
            await system.stop()
            throw error
        }

        // Bridge tasks: drain each provider's events into the store. The
        // AsyncStream is closed when the provider's stop() finishes the
        // continuation, at which point the for-await exits.
        let micEvents = mic.events
        let systemEvents = system.events
        let micBridge = Task {
            for await event in micEvents {
                await storeRef.ingest(event, source: .mic)
            }
        }
        let systemBridge = Task {
            for await event in systemEvents {
                await storeRef.ingest(event, source: .system)
            }
        }

        micProvider = mic
        systemProvider = system
        bridgeTasks = [micBridge, systemBridge]
    }

    /// Stops both providers, waits for bridge tasks to drain, flushes any
    /// pending interim segments to the DB.
    func stop() async {
        if let mic = micProvider { await mic.stop() }
        if let system = systemProvider { await system.stop() }
        for task in bridgeTasks {
            _ = await task.value
        }
        bridgeTasks = []
        let storeRef = store
        await MainActor.run {
            Task { await storeRef.flush() }
        }
        // Note: flush is fire-and-forget under MainActor.run because flush
        // itself is async and we don't want to block the actor here. Tests
        // that need flush completion can `await store.flush()` directly.
        micProvider = nil
        systemProvider = nil
    }
}

/// Placeholder used by AppCoordinator's default factory before
/// `SarvamProvider` lands in commit 5. Emits `.connected` once and then
/// idles. Discarded once the production factory points at `SarvamProvider`.
final class EmptyTranscriptionProvider: TranscriptionProvider, @unchecked Sendable {
    nonisolated let events: AsyncStream<TranscriptionEvent>
    private nonisolated let continuation: AsyncStream<TranscriptionEvent>.Continuation

    init() {
        var cont: AsyncStream<TranscriptionEvent>.Continuation?
        let stream = AsyncStream<TranscriptionEvent> { capturedCont in cont = capturedCont }
        events = stream
        guard let captured = cont else {
            preconditionFailure("AsyncStream did not yield continuation")
        }
        continuation = captured
    }

    func start(meetingID _: String, source _: PCMChunk.Source, audioStream: AsyncStream<PCMChunk>) async throws {
        continuation.yield(.connected)
        // Drain the audio stream so the producer doesn't stall.
        Task {
            for await _ in audioStream {}
        }
    }

    func stop() async {
        continuation.finish()
    }
}
