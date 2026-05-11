import Foundation
import GRDB

/// Owns the Sarvam batch diarization pipeline lifecycle for one meeting:
///
///   1. Skip-if-empty gate — meetings with no `transcript_segments`
///      rows pre-batch (instant stops) don't trigger any API calls.
///   2. Status flips to `.pending` on both the DB row and the in-memory
///      `DiarizationStatusStore`.
///   3. Two `diarize` closures fire concurrently — one for `mic.wav`
///      and one for `system.wav`. Per-stream submission preserves the
///      `(meeting_id, source, raw_speaker_id)` attribution the data
///      model needs (DECISIONS.md 2026-05-09 per-stream entry).
///   4. On both succeeding, `swapInDatabase` runs as one transaction:
///      capture mic-0 rename, DELETE old `speakers` (cascading to
///      `transcript_segments`), INSERT new `speakers` with Path B
///      default labels, INSERT new `transcript_segments` with
///      remapped speaker IDs, reapply the captured mic-0 rename.
///   5. On either failing, status flips to `.failed(message:)` and the
///      pre-batch DB rows stay untouched — the user still sees the
///      streaming-time labels.
///
/// Authoritative-replace semantics (DECISIONS.md 2026-05-08 Path B,
/// 2026-05-09 batch-is-authoritative). Single exception: the
/// mid-meeting `(mic, 0)` rename is preserved across the swap
/// (Decision 17 / Revision 2).
actor DiarizationService {
    /// Closure shape the service uses to invoke a batch diarizer per
    /// WAV. Production wires this to `SarvamBatchClient.diarize`;
    /// tests inject a mock-returning closure (see
    /// `DiarizationServiceTests`). Lifting the dependency to a closure
    /// rather than a protocol keeps the type surface minimal — there's
    /// only one production diarizer for now and the closure is the
    /// smallest abstraction that lets tests inject deterministic
    /// results.
    typealias DiarizeFunction = @Sendable (URL, String) async throws -> SarvamBatchResult

    /// Default language for batch transcription. Mirrors the value
    /// `SarvamProvider` uses for streaming (Phase 2). When Phase 5+
    /// adds per-meeting language settings, this becomes a parameter.
    static let defaultLanguageCode = "en-IN"

    let database: Database
    let statusStore: DiarizationStatusStore
    let settings: SettingsStore
    let diarize: DiarizeFunction

    init(
        database: Database,
        statusStore: DiarizationStatusStore,
        settings: SettingsStore,
        diarize: @escaping DiarizeFunction
    ) {
        self.database = database
        self.statusStore = statusStore
        self.settings = settings
        self.diarize = diarize
    }

    /// Runs the post-meeting batch diarization for one meeting.
    /// Fire-and-forget from `AppCoordinator.stopMeeting` — never
    /// throws; failures land on the status row and the
    /// `DiarizationStatusStore` so the UI can render them.
    func runForMeeting(meetingID: String, micWAV: URL, systemWAV: URL) async {
        let preCount = await (try? preBatchSegmentCount(meetingID: meetingID)) ?? 0
        guard preCount > 0 else { return } // edge case A: empty meeting

        await applyStatus(meetingID: meetingID, status: .pending)
        let displayName = await resolveDisplayName()

        let results: (mic: SarvamBatchResult, system: SarvamBatchResult)
        do {
            results = try await submitBoth(micWAV: micWAV, systemWAV: systemWAV)
        } catch {
            await applyStatus(
                meetingID: meetingID,
                status: .failed(message: String(describing: error))
            )
            return
        }
        do {
            try await swapInDatabase(
                meetingID: meetingID,
                results: results,
                displayName: displayName
            )
        } catch {
            await applyStatus(
                meetingID: meetingID,
                status: .failed(message: "swap-in-database failed: \(error)")
            )
            return
        }
        // Phase 3.5: speaker bleed-through dedup. Runs in a SEPARATE
        // `database.queue.write` block from the swap, not the same
        // transaction. The two-write design is intentional:
        //   - Testability: `SpeakerBleedDeduper` has independent DB-
        //     driven coverage (`SpeakerBleedDedupIntegrationTests`)
        //     that exercises a swap-then-dedup-then-assert flow
        //     without a giant transaction-scoped fixture.
        //   - Maintainability: `swapInDatabase` stays under its
        //     existing complexity budget.
        // Trade-off: there's a millisecond-scale crash window between
        // the writes; if execa crashes BETWEEN swap and dedup, the
        // user sees Phase-3-style duplicates in the meeting detail
        // view. Recovery: Re-run diarization re-applies both. Future
        // maintainers tempted to collapse this into one transaction:
        // please read this comment + the Phase 3.5 plan first.
        await runDedupPass(meetingID: meetingID)
        await applyStatus(meetingID: meetingID, status: .completed(at: Date()))
    }

    private func runDedupPass(meetingID: String) async {
        // Two settings, orthogonal:
        //   - `auto_speaker_bleed_dedup` decides WHETHER the pass runs.
        //   - `bleed_dedup_algorithm_version` decides WHICH algorithm
        //     (`.v1` = Phase 3.5 Jaccard; `.v2` = Phase 3.5b
        //     containment + Porter-light stemming + concatenation
        //     pre-pass + cross-validation post-pass).
        // Both default-on / default-v2 via the SettingsStore accessors;
        // direct DB edit is the only way to disable until Phase 5's
        // Settings UI ships.
        let enabled = await (try? settings.autoSpeakerBleedDedup()) ?? true
        guard enabled else { return }
        let version = await (try? settings.bleedDedupAlgorithmVersion()) ?? .v2
        do {
            let result = try await database.queue.write { db in
                try SpeakerBleedDeduper.dedup(meetingID: meetingID, version: version, in: db)
            }
            if !result.dedupedPairs.isEmpty {
                let count = result.dedupedPairs.count
                _ = count // os_log site (Phase 4 wires the central log handle).
            }
        } catch {
            // Dedup is a polish pass; failure is non-fatal. The swap
            // succeeded, so the meeting is still usable — just with
            // Phase-3-style duplicates visible. The user can Re-run
            // diarization to retry.
        }
    }

    // MARK: - Pipeline pieces

    private func resolveDisplayName() async -> String {
        let stored = await (try? settings.string(forKey: .displayName)) ?? nil
        return stored ?? "You"
    }

    private func submitBoth(
        micWAV: URL,
        systemWAV: URL
    ) async throws -> (mic: SarvamBatchResult, system: SarvamBatchResult) {
        async let micCall = diarize(micWAV, Self.defaultLanguageCode)
        async let systemCall = diarize(systemWAV, Self.defaultLanguageCode)
        let micResult = try await micCall
        let systemResult = try await systemCall
        return (mic: micResult, system: systemResult)
    }

    /// Drives both the in-memory store and the persistent `meetings`
    /// row from a single `DiarizationStatus` value. Done as one
    /// helper so the four call sites (pending / failed-batch /
    /// failed-swap / completed) stay one line each, and the
    /// status-string mapping stays in one place.
    private func applyStatus(meetingID: String, status: DiarizationStatus) async {
        await statusStore.update(meetingID: meetingID, status: status)
        try? await persistStatus(meetingID: meetingID, status: status)
    }
}
