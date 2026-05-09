import Foundation

/// Default-label helpers + relative-time helper used by
/// `TranscriptStore`. Lifted out of the main file to keep the
/// `@MainActor @Observable final class TranscriptStore` body under
/// the type-body-length cap. Behaviour is unchanged.
enum TranscriptDefaultLabel {
    /// Phase 2 (Path B) label policy. Sarvam streaming STT does not
    /// support diarization, so live events always arrive with
    /// `raw_speaker_id == 0` — both streams collapse to a single
    /// label. Multi-speaker labels are produced post-hoc via
    /// Sarvam's batch API in Phase 3+.
    ///
    /// Defensive defaults are kept for `raw_speaker_id != 0` so the
    /// code behaves sanely if (a) we run under a provider that does
    /// diarize live (Deepgram, Phase 6) or (b) Phase 3's batch-
    /// backfill writes through this same code path. The
    /// `(mic, N≥1)` and `(system, N≥1)` labels here are
    /// placeholders that the Phase 3 rename UI overwrites.
    static func label(
        source: PCMChunk.Source,
        rawSpeakerID: Int,
        displayName: String?
    ) -> String {
        switch source {
        case .mic:
            rawSpeakerID == 0 ? (displayName ?? "You") : "In-room \(rawSpeakerID + 1)"
        case .system:
            rawSpeakerID == 0 ? "Remote" : "Speaker \(rawSpeakerID + 1)"
        }
    }
}

extension TimeInterval {
    /// Floors at zero defensively; Sarvam streaming doesn't emit
    /// interim events today (per the commit 5 probe) so the call is
    /// unreachable in production. Phase 6's Deepgram path will
    /// exercise it; if Deepgram emits absolute timestamps for
    /// interims (it does), this conversion is correct.
    static func relativeSeconds(providerMs: Int) -> TimeInterval {
        TimeInterval(max(0, providerMs)) / 1000
    }
}
