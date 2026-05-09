import Foundation

/// Provider-agnostic STT contract. One concrete provider (Sarvam) lives in
/// Phase 2; Deepgram and friends arrive in Phase 6.
///
/// Lifecycle:
/// - `start(meetingID:source:audioStream:)` connects upstream and begins
///   draining `audioStream` into the wire. Throws if the initial connection
///   fails outright; subsequent transient failures are surfaced as `.error`
///   events on `events` and recovered via in-provider reconnect.
/// - `stop()` flushes any in-flight buffers, drains the server's final
///   responses, and tears down the wire. Idempotent.
///
/// `events` is single-consumer: TranscriptionService is the only intended
/// reader, and it bridges into TranscriptStore.
protocol TranscriptionProvider: Sendable {
    func start(
        meetingID: String,
        source: PCMChunk.Source,
        audioStream: AsyncStream<PCMChunk>
    ) async throws
    func stop() async
    var events: AsyncStream<TranscriptionEvent> { get }
    /// Whether `TranscriptToken.startMs` / `endMs` represent absolute
    /// positions in the audio stream the provider received (`true`), or
    /// the provider can't supply absolute timestamps and uses the
    /// `endMs == segment-duration-in-ms` convention (`false`). Sarvam
    /// streaming returns `false` (its wire format only carries
    /// `metrics.audio_duration` per message); Deepgram in Phase 6 will
    /// return `true`. `TranscriptStore.applyFinal` switches on this to
    /// decide whether to trust the token's timestamps directly or fall
    /// back to wall-clock-since-meeting-start.
    var providesAbsoluteTimestamps: Bool { get }
}

extension TranscriptionProvider {
    /// Default: most providers will support absolute timestamps. Only
    /// providers that can't (Sarvam streaming, today) override to false.
    var providesAbsoluteTimestamps: Bool {
        true
    }
}

/// Normalized event shape that TranscriptionService and TranscriptStore see,
/// regardless of which underlying provider is wired up.
///
/// Provider adapters (`SarvamProvider`, future `DeepgramProvider`) translate
/// their wire format into this enum, so downstream code never branches on
/// provider.
enum TranscriptionEvent: Equatable {
    /// Connection to the provider succeeded. UI can clear any "Reconnecting…"
    /// banner.
    case connected
    /// Connection dropped. Subsequent reconnect attempts may produce another
    /// `.connected` event; if reconnect is exhausted the provider emits
    /// `.error(.reconnectExhausted)` and stops.
    case disconnected
    /// Interim (non-final) transcript token. Replaces any prior interim with
    /// the same `(speakerID, source)` key in TranscriptStore.
    case interim(TranscriptToken)
    /// Finalized transcript token. Committed to `transcript_segments`;
    /// clears the matching interim from TranscriptStore.
    case final(TranscriptToken)
    /// Provider-level error. Some are recoverable (transient socket); some
    /// are terminal (auth failed, reconnect exhausted).
    case error(TranscriptionError)
}

/// One transcript chunk as the provider returned it. Time fields are in ms,
/// **relative to the start of the audio stream the provider received** — not
/// relative to wall clock or to the meeting. TranscriptStore translates
/// these into meeting-relative ms before insert.
///
/// **Convention when the source provider returns
/// `providesAbsoluteTimestamps == false`** (Sarvam streaming today): the
/// provider sets `startMs = 0` and stores the segment duration in ms in
/// `endMs`. `TranscriptStore.applyFinal` reads the per-source flag and
/// substitutes wall-clock-since-meeting-start when the flag is false, so
/// downstream code never has to second-guess the field's meaning.
struct TranscriptToken: Equatable {
    var startMs: Int
    var endMs: Int
    /// The provider's diarized speaker index. With both mic and system
    /// streams using `diarization=true`, this is meaningful for both
    /// sources. The `(meeting_id, source, raw_speaker_id)` tuple is the
    /// stable key in the `speakers` table.
    var speakerID: Int
    var text: String
    /// 0.0 … 1.0 if provider emits one; nil otherwise.
    var confidence: Double?
    /// Per-token language tag for code-switched audio. Sarvam emits this for
    /// Hi-en streams (e.g. "hi", "en"); other providers may not.
    var language: String?
}

/// Provider-level errors normalized across adapters.
enum TranscriptionError: Equatable, Error {
    /// The auth credential the provider was constructed with was rejected
    /// at upgrade time. Not recoverable inside the provider — surface to
    /// the user and let them re-enter the key.
    case authFailed
    /// Reconnect attempts exhausted (5 attempts × exponential backoff).
    /// Terminal for the rest of the meeting unless the user explicitly
    /// resumes via the LiveMeetingView UI.
    case reconnectExhausted
    /// Catch-all for provider-specific errors that don't fit elsewhere.
    /// `description` is unstructured.
    case other(String)
}
