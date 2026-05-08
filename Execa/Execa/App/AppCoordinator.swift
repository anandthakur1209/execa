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
    let keychain: KeychainStore
    let permissions: PermissionsService
    let audioCapture: AudioCaptureService
    let transcription: TranscriptionService
    let transcriptStore: TranscriptStore
    private let transcriptionProviderFactory: TranscriptionProviderFactory

    init(
        transcriptionProviderFactory: @escaping TranscriptionProviderFactory = { _, key in SarvamProvider(apiKey: key) }
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
        _ = try await audioCapture.stop()
    }
}
