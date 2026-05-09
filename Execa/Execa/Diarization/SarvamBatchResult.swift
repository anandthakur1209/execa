import Foundation

/// Parsed Sarvam batch STT response with `with_diarization=true`. Wire
/// shape is captured by the commit-2 discovery probe; the parser lands
/// in commit 3 alongside `SarvamBatchClient`. This commit's skeleton
/// holds only the public types so the rest of Phase 3's plumbing
/// (`DiarizationService`, tests) can compile against the contract
/// without waiting on the probe.
struct SarvamBatchResult: Equatable {
    var segments: [BatchSegment]

    /// One diarized segment as the batch endpoint emits it. `speakerID`
    /// is the cluster ID Sarvam assigns within this single batch call —
    /// it is meaningful only relative to the file submitted, not across
    /// files (we submit `mic.wav` and `system.wav` separately, so a
    /// `speakerID` of `0` in the mic result and `0` in the system
    /// result are unrelated speakers). `DiarizationService.swapInDatabase`
    /// rebases these into the per-meeting `(source, raw_speaker_id)`
    /// space.
    struct BatchSegment: Equatable {
        var speakerID: Int
        var startMs: Int
        var endMs: Int
        var text: String
        var languageCode: String?
    }
}
