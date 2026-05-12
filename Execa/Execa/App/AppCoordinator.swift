import Foundation
import GRDB

actor AppCoordinator {
    /// Factory the coordinator uses to create per-source transcription
    /// providers at meeting-start. Bound by ExecaApp at app launch (commit 5
    /// switches this to a `SarvamProvider` factory). The string parameter is
    /// the validated-non-empty Sarvam API key — captured by
    /// `startMeeting()`'s gate before the factory is invoked.
    typealias TranscriptionProviderFactory = @Sendable (PCMChunk.Source, String) -> any TranscriptionProvider

    nonisolated let database: Database
    private let settings: SettingsStore
    nonisolated let keychain: KeychainStore
    nonisolated let permissions: PermissionsService
    nonisolated let audioCapture: AudioCaptureService
    nonisolated let transcription: TranscriptionService
    nonisolated let transcriptStore: TranscriptStore
    nonisolated let diarizationStatusStore: DiarizationStatusStore
    nonisolated let speakerLabelManager: SpeakerLabelManager
    private let diarization: DiarizationService
    private let transcriptionProviderFactory: TranscriptionProviderFactory

    /// Tests pass an in-memory or temp-file `database` here so they can
    /// seed state and observe writes without touching the user's
    /// `~/Library/Application Support/com.anandthakur.execa/db.sqlite3`.
    /// Production call sites pass `nil` (the default), which falls back
    /// to `Database.make()`'s standard file-backed location.
    init(
        transcriptionProviderFactory: @escaping TranscriptionProviderFactory = { _, key in
            SarvamProvider(apiKey: key)
        },
        diarizeFunction: DiarizationService.DiarizeFunction? = nil,
        database injectedDatabase: Database? = nil
    ) async throws {
        let database = try injectedDatabase ?? Database.make()
        // ^ `Database.make()` throws; the `try` covers it. When
        // `injectedDatabase` is non-nil, `??` short-circuits and
        // `make()` is never invoked.
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
        speakerLabelManager = SpeakerLabelManager(database: database)
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

    /// Renames a single speaker AND propagates the new label to any
    /// live `TranscriptStore.lines` already attributed to it. Without
    /// the propagation, past transcript turns kept their stale
    /// captured `speakerLabel` (BUG 7). UI call sites should use this
    /// wrapper instead of `speakerLabelManager.rename` directly.
    func renameSpeaker(speakerID: Int64, to newLabel: String) async throws {
        try await speakerLabelManager.rename(speakerID: speakerID, to: newLabel)
        let trimmed = newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let store = transcriptStore
        await MainActor.run { store.applyRename(speakerID: speakerID, newLabel: trimmed) }
    }

    /// Merges two speakers AND propagates the merge target's label
    /// onto any live transcript turns attributed to the source. The
    /// segments themselves stay attached to the source row (merge is
    /// a display-time alias, not a re-attribution); only `lines`'
    /// `speakerLabel` is rewritten so the user sees the post-merge
    /// label immediately. UI call sites should use this wrapper.
    ///
    /// Phase 3.5c: auto-rerun dedup as the final step. A user-driven
    /// merge can flip which segments qualify as bleed (the Sarvam
    /// over-segmentation case), so the dedup state captured at swap
    /// time is stale relative to the new effective-speaker topology.
    /// Re-derive against the merged topology; `runDedupPass` is
    /// reset-first so stale audit FKs get wiped before re-derivation.
    func mergeSpeakers(sourceSpeakerID: Int64, intoTargetSpeakerID targetSpeakerID: Int64) async throws {
        let meetingID = await fetchMeetingID(forSpeakerID: sourceSpeakerID)
        try await speakerLabelManager.merge(
            sourceSpeakerID: sourceSpeakerID,
            intoTargetSpeakerID: targetSpeakerID
        )
        let targetLabel = await fetchSpeakerLabel(speakerID: targetSpeakerID)
        let store = transcriptStore
        await MainActor.run {
            store.applyMerge(sourceSpeakerID: sourceSpeakerID, targetLabel: targetLabel)
        }
        if let meetingID {
            await diarization.rerunDedupForMeeting(meetingID: meetingID)
        }
    }

    /// Splits the segment off into a new speaker AND retargets the
    /// matching live `TranscriptLine` (by `databaseSegmentID`) at the
    /// new speakers row. UI call sites should use this wrapper.
    ///
    /// Phase 3.5c: auto-rerun dedup as the final step. Splitting a
    /// segment can both flag previously-unflagged segments (whose
    /// match was hidden behind the old grouping) and clear stale FKs
    /// for the split-off segment, so re-derive against the post-split
    /// topology. Reset-first semantics apply (see `mergeSpeakers`).
    @discardableResult
    func splitSegment(segmentID: Int64, intoNewLabel newLabel: String) async throws -> Int64 {
        let meetingID = await fetchMeetingID(forSegmentID: segmentID)
        let newSpeakerID = try await speakerLabelManager.split(
            segmentID: segmentID,
            intoNewLabel: newLabel
        )
        let trimmed = newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let store = transcriptStore
        await MainActor.run {
            store.applySplit(segmentID: segmentID, newSpeakerID: newSpeakerID, newLabel: trimmed)
        }
        if let meetingID {
            await diarization.rerunDedupForMeeting(meetingID: meetingID)
        }
        return newSpeakerID
    }

    private func fetchSpeakerLabel(speakerID: Int64) async -> String {
        await (try? database.queue.read { db in
            try SpeakerQueries.displayLabel(speakerID: speakerID, in: db)
        }) ?? nil ?? ""
    }

    /// Resolves the meeting_id for a given `speakers.id`. Used by
    /// `mergeSpeakers` to thread the meeting ID into the post-merge
    /// dedup re-run hook. Returns `nil` if the speaker row doesn't
    /// resolve — in that case `SpeakerLabelManager.merge` would have
    /// thrown anyway, so the caller's guard skips the re-run.
    private func fetchMeetingID(forSpeakerID speakerID: Int64) async -> String? {
        await (try? database.queue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT meeting_id FROM speakers WHERE id = ?",
                arguments: [speakerID]
            )
        }) ?? nil
    }

    /// Resolves the meeting_id for a given `transcript_segments.id`.
    /// Used by `splitSegment` for the post-split dedup re-run hook.
    /// Returns `nil` if the segment row doesn't resolve.
    private func fetchMeetingID(forSegmentID segmentID: Int64) async -> String? {
        await (try? database.queue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT meeting_id FROM transcript_segments WHERE id = ?",
                arguments: [segmentID]
            )
        }) ?? nil
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
