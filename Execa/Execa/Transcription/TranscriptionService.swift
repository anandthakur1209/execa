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

    /// Starts both providers for a fresh meeting. Resets the transcript
    /// store via `beginMeeting`, then attaches new providers. The caller
    /// is responsible for having validated credentials and bound them
    /// inside `providerFactory` before this is called.
    func start(providerFactory: ProviderFactory, context: StartContext) async throws {
        let storeRef = store
        await MainActor.run {
            storeRef.beginMeeting(
                meetingID: context.meetingID,
                startedAt: context.startedAt,
                displayName: context.displayName
            )
        }
        try await attachProviders(providerFactory: providerFactory, context: context)
    }

    /// Re-attaches providers without resetting the transcript store.
    /// Used by the LiveMeetingView "Resume" button when the previous
    /// providers exhausted their reconnect budget. The same audio
    /// streams keep flowing — new providers pick up from wherever the
    /// `AsyncStream` buffer is, so audio captured during the dead window
    /// is missed but the meeting continues without a transcript reset.
    func resume(providerFactory: ProviderFactory, context: StartContext) async throws {
        // Tear down whatever's left of the old provider trees first.
        await stopProvidersOnly()
        try await attachProviders(providerFactory: providerFactory, context: context)
    }

    private func attachProviders(providerFactory: ProviderFactory, context: StartContext) async throws {
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
        // continuation, at which point the for-await exits. Capture each
        // provider's `providesAbsoluteTimestamps` flag once at bridge
        // start and pass it through to `store.ingest` so TranscriptStore
        // knows whether to use the token's startMs/endMs directly or
        // fall back to wall-clock-since-meeting-start.
        let storeRef = store
        let micEvents = mic.events
        let systemEvents = system.events
        let micProvidesAbsolute = mic.providesAbsoluteTimestamps
        let systemProvidesAbsolute = system.providesAbsoluteTimestamps
        let micBridge = Task {
            for await event in micEvents {
                await storeRef.ingest(event, source: .mic, providesAbsoluteTimestamps: micProvidesAbsolute)
            }
        }
        let systemBridge = Task {
            for await event in systemEvents {
                await storeRef.ingest(event, source: .system, providesAbsoluteTimestamps: systemProvidesAbsolute)
            }
        }

        micProvider = mic
        systemProvider = system
        bridgeTasks = [micBridge, systemBridge]
    }

    /// Stops providers + bridges only. Doesn't flush the store. Used
    /// internally by `resume()` to drop the dead provider tree before
    /// attaching a fresh one.
    private func stopProvidersOnly() async {
        if let mic = micProvider { await mic.stop() }
        if let system = systemProvider { await system.stop() }
        for task in bridgeTasks {
            _ = await task.value
        }
        bridgeTasks = []
        micProvider = nil
        systemProvider = nil
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
