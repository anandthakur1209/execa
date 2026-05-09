import Foundation

actor AppCoordinator {
    /// Factory the coordinator uses to create per-source transcription
    /// providers at meeting-start. Bound by ExecaApp at app launch (commit 5
    /// switches this to a `SarvamProvider` factory). The string parameter is
    /// the validated-non-empty Sarvam API key — captured by
    /// `startMeeting()`'s gate before the factory is invoked.
    typealias TranscriptionProviderFactory = @Sendable (PCMChunk.Source, String) -> any TranscriptionProvider

    private let database: Database
    private let settings: SettingsStore
    nonisolated let keychain: KeychainStore
    nonisolated let permissions: PermissionsService
    nonisolated let audioCapture: AudioCaptureService
    nonisolated let transcription: TranscriptionService
    nonisolated let transcriptStore: TranscriptStore
    nonisolated let diarizationStatusStore: DiarizationStatusStore
    private let diarization: DiarizationService
    private let transcriptionProviderFactory: TranscriptionProviderFactory

    init(
        transcriptionProviderFactory: @escaping TranscriptionProviderFactory = { _, key in
            SarvamProvider(apiKey: key)
        },
        diarizeFunction: DiarizationService.DiarizeFunction? = nil
    ) async throws {
        let database = try Database.make()
        self.database = database
        let settings = SettingsStore(database: database)
        self.settings = settings
        let keychain = KeychainStore()
        self.keychain = keychain
        let permissions = PermissionsService()
        self.permissions = permissions
        audioCapture = AudioCaptureService(
            mic: MicrophoneSource(),
            system: ScreenCaptureKitSource(),
            permissions: permissions,
            database: database
        )
        let transcriptStore = await TranscriptStore(database: database)
        self.transcriptStore = transcriptStore
        transcription = TranscriptionService(store: transcriptStore)
        self.transcriptionProviderFactory = transcriptionProviderFactory

        // Diarization. Default `diarizeFunction` reads the Sarvam key
        // from Keychain at call time and creates a fresh
        // `SarvamBatchClient` per invocation — same per-call style
        // the streaming `transcriptionProviderFactory` uses, and lets
        // a Keychain key updated mid-session take effect on the next
        // diarization without an app restart.
        let statusStore = await DiarizationStatusStore()
        diarizationStatusStore = statusStore
        let resolvedDiarize: DiarizationService.DiarizeFunction
        if let injected = diarizeFunction {
            resolvedDiarize = injected
        } else {
            // Capture `keychain` (a value-typed wrapper around the
            // SecItem APIs) so the closure stays Sendable.
            let keychainCapture = keychain
            resolvedDiarize = { @Sendable wavURL, languageCode in
                let serviceName = KeychainStore.serviceName(forProvider: "sarvam")
                let key = (try? keychainCapture.get(service: serviceName, account: "default")) ?? nil
                guard let key, !key.isEmpty else {
                    throw SarvamBatchClientError.uploadFailed(
                        statusCode: 0,
                        message: "no Sarvam key available for batch diarization"
                    )
                }
                let client = SarvamBatchClient(apiKey: key)
                return try await client.diarize(wavURL: wavURL, languageCode: languageCode)
            }
        }
        diarization = DiarizationService(
            database: database,
            statusStore: statusStore,
            settings: settings,
            diarize: resolvedDiarize
        )
    }

    func currentDisplayName() async throws -> String? {
        try await settings.string(forKey: .displayName)
    }

    func setDisplayName(_ name: String) async throws {
        try await settings.setString(name, forKey: .displayName)
    }

    func isFirstRunComplete() async throws -> Bool {
        try await settings.bool(forKey: .firstRunComplete)
    }

    func markFirstRunComplete() async throws {
        try await settings.setBool(true, forKey: .firstRunComplete)
    }

    @discardableResult
    func startMeeting() async throws -> URL {
        // Phase 2 missing-key gate: refuse to start if no Sarvam key is in
        // Keychain. Surface .error(.missingSTTKey) so the menu bar shows the
        // red-triangle icon, then throw so the caller can stop. Audio
        // capture is not attempted; no `meetings` row is inserted; no
        // meetings/<ULID>/ directory is created.
        let storedKey: String?
        do {
            storedKey = try keychain.get(
                service: KeychainStore.serviceName(forProvider: "sarvam"),
                account: "default"
            )
        } catch {
            storedKey = nil
        }
        guard let validKey = storedKey, !validKey.isEmpty else {
            await audioCapture.recordPreflightError(.missingSTTKey)
            throw MeetingError.missingSTTKey
        }

        let id = ULID.generate()
        let directory = try await audioCapture.start(meetingID: id)

        let displayName = await (try? settings.string(forKey: .displayName)) ?? nil
        let startedAt = Date()
        let factory = transcriptionProviderFactory
        let context = TranscriptionService.StartContext(
            meetingID: id,
            startedAt: startedAt,
            displayName: displayName,
            micStream: audioCapture.micSttStream,
            systemStream: audioCapture.systemSttStream
        )
        do {
            try await transcription.start(
                providerFactory: { source in factory(source, validKey) },
                context: context
            )
        } catch {
            // Transcription startup is best-effort in Phase 2: if it fails,
            // we still keep the audio recording. Phase 6's router will
            // turn this into a real failover. Errors are silently swallowed
            // here; the UI's connection-state pill (Phase 2 commit 7)
            // surfaces ongoing trouble.
        }
        return directory
    }

    func stopMeeting() async throws {
        // Stop transcription first so providers see EOS and flush, before
        // audio capture closes its archival writers.
        await transcription.stop()
        let stoppedDirectory = try await audioCapture.stop()

        // Phase 3 auto-trigger: kick off post-meeting batch diarization
        // if the `auto_diarization` setting allows. Fire-and-forget so
        // the UI returns to `.idle` promptly; the
        // `DiarizationStatusStore` publishes status updates as the
        // batch progresses (`MeetingDetailView` observes them).
        guard let stoppedDirectory else { return }
        guard let endedMeetingID = audioCapture.lastEndedMeetingID else { return }
        let auto = await (try? settings.autoDiarization()) ?? true
        guard auto else { return }
        let micWAV = stoppedDirectory.appendingPathComponent("mic.wav")
        let systemWAV = stoppedDirectory.appendingPathComponent("system.wav")
        let diarization = diarization
        Task.detached {
            await diarization.runForMeeting(
                meetingID: endedMeetingID,
                micWAV: micWAV,
                systemWAV: systemWAV
            )
        }
    }

    /// Re-run diarization on demand (Phase 3 commit 7's
    /// "Re-run diarization" button + commit 4's failure-retry path).
    /// Always available regardless of the `auto_diarization` setting.
    func rerunDiarization(meetingID: String) async {
        let directory: URL
        do {
            directory = try MeetingsDirectory.url(forMeetingID: meetingID)
        } catch {
            return
        }
        let micWAV = directory.appendingPathComponent("mic.wav")
        let systemWAV = directory.appendingPathComponent("system.wav")
        await diarization.runForMeeting(
            meetingID: meetingID,
            micWAV: micWAV,
            systemWAV: systemWAV
        )
    }

    /// Wired to the menu bar's "Dismiss" button when the state machine is
    /// in `.error(...)`. Sends the state machine back to `.idle` so the
    /// menu reverts to the default "Start Meeting" layout. The previous
    /// implementation re-invoked `startMeeting()`, which immediately
    /// re-tripped any preflight error (e.g. missing Sarvam key) — making
    /// Dismiss visibly inert.
    func dismissError() async {
        await audioCapture.clearError()
    }

    /// Asks each existing transcription provider to restart its
    /// connection logic. No-op if not currently `.recording`. The
    /// transcript store is preserved; the audio-producer tasks are
    /// preserved (so audio captured during the dead window stays
    /// available in each provider's ring buffer); only the connection
    /// supervisors are restarted. Audio captured during the dead
    /// window flows out via the new socket once it connects, via the
    /// supervisor's normal ring-drain path.
    func resumeTranscription() async {
        let state = await audioCapture.state
        guard case .recording = state else { return }
        await transcription.retry()
    }
}
