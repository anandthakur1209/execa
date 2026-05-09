import Foundation

/// Owns the Sarvam batch diarization pipeline lifecycle:
/// auto-trigger at `stopMeeting` (gated by the `auto_diarization`
/// setting), parallel batch calls per source, swap-in-DB transaction,
/// status updates published to `DiarizationStatusStore`.
///
/// Skeleton commit (commit 1) — only `init` lands here. The full
/// `runForMeeting(meetingID:micWAV:systemWAV:)` implementation, the
/// per-source batch fan-out, and the swap-in-DB transaction with the
/// Decision-17 mic-rename preservation all land in commit 4 once the
/// `SarvamBatchClient` (commit 3) is real.
actor DiarizationService {
    private let database: Database
    private let statusStore: DiarizationStatusStore
    private let batchClientFactory: @Sendable () -> SarvamBatchClient

    init(
        database: Database,
        statusStore: DiarizationStatusStore,
        batchClientFactory: @escaping @Sendable () -> SarvamBatchClient
    ) {
        self.database = database
        self.statusStore = statusStore
        self.batchClientFactory = batchClientFactory
    }

    /// Stub — full implementation in commit 4.
    func runForMeeting(meetingID _: String, micWAV _: URL, systemWAV _: URL) async {
        // No-op until commit 4. Tests that exercise this path with a
        // mock batch client also land in commit 4.
    }
}
