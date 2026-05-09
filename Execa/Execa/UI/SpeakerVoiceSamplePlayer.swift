import AVFoundation
import Foundation
import GRDB

/// Plays a 3-second sample of a speaker's audio drawn from the
/// finalized per-source WAV files (`mic.wav` / `system.wav`). Used by
/// `MeetingDetailView` post-meeting; mid-meeting playback is gated
/// off by Decision 5.
///
/// Merged-speaker behaviour (Phase 3 Revision 5): walks the
/// `merged_into_speaker_id` alias chain to the canonical speaker, then
/// fetches that canonical speaker's most-recent transcript_segments
/// row. Plays a 3 s window ending at the segment's `end_ms`. The
/// audio bytes come from the WAV named by **the segment's** source —
/// which after a cross-source merge may differ from the canonical
/// speaker's row source. The segment-row source records the actual
/// recording stream the audio was captured on, and that's what the
/// WAV file reflects.
@MainActor
final class SpeakerVoiceSamplePlayer {
    private let database: Database
    private var player: AVAudioPlayer?

    /// Default sample window length. 3 s matches Phase 3 plan.
    static let sampleDurationMs: Int = 3000

    init(database: Database) {
        self.database = database
    }

    /// Play the sample for `speakerID`. Errors during DB lookup or
    /// AVAudioPlayer setup return `false` so the UI can render a
    /// disabled state rather than crash.
    @discardableResult
    func play(speakerID: Int64, meetingID: String) async -> Bool {
        guard let window = try? await Self.windowToPlay(
            speakerID: speakerID,
            meetingID: meetingID,
            database: database
        ) else { return false }
        do {
            let audioFile = try AVAudioFile(forReading: window.wavURL)
            // Seek by setting `currentTime` to the start-of-window in
            // seconds. AVAudioPlayer's seek precision is ms-grain on
            // WAV; close enough for a 3 s preview.
            let player = try AVAudioPlayer(contentsOf: window.wavURL)
            self.player = player
            player.currentTime = TimeInterval(window.startMs) / 1000.0
            player.prepareToPlay()
            player.play()
            // Auto-stop after the window length.
            Task { [weak self] in
                let nanos = UInt64((window.endMs - window.startMs) * 1_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                self?.player?.stop()
            }
            // Reference `audioFile` so it isn't released before
            // AVAudioPlayer reads — paranoid; AVAudioPlayer copies
            // the bytes itself, but the explicit retain is harmless.
            _ = audioFile
            return true
        } catch {
            return false
        }
    }

    /// Testable accessor: returns the `(wavURL, startMs, endMs)` the
    /// player would use without actually playing. Tests assert this
    /// to verify Revision 5's alias-walking + segment-source rule
    /// without needing audio device permissions.
    static func windowToPlay(
        speakerID: Int64,
        meetingID: String,
        database: Database,
        durationMs: Int = SpeakerVoiceSamplePlayer.sampleDurationMs
    ) async throws -> SamplePlaybackWindow? {
        try await database.queue.read { db in
            let canonical = try SpeakerQueries.canonicalSpeakerID(speakerID, in: db)
            // Most-recent finalized segment for the canonical speaker.
            // ORDER BY end_ms DESC LIMIT 1 — `end_ms` is a wall-clock
            // offset within the meeting, and "most recent" matches
            // the user's expectation of "latest snippet of this
            // person's voice."
            let row = try Row.fetchOne(
                db,
                sql: """
                SELECT s.source AS source, t.end_ms AS end_ms
                FROM transcript_segments t
                JOIN speakers s ON s.id = t.speaker_id
                WHERE t.meeting_id = ? AND t.speaker_id = ? AND t.is_final = 1
                ORDER BY t.end_ms DESC, t.id DESC
                LIMIT 1
                """,
                arguments: [meetingID, canonical]
            )
            guard let row,
                  let segmentSource: String = row["source"],
                  let endMs: Int = row["end_ms"]
            else {
                return nil
            }
            let startMs = max(0, endMs - durationMs)
            let wavURL = try Self.wavURL(forMeetingID: meetingID, source: segmentSource)
            return SamplePlaybackWindow(
                wavURL: wavURL,
                startMs: startMs,
                endMs: endMs
            )
        }
    }

    private nonisolated static func wavURL(forMeetingID meetingID: String, source: String) throws -> URL {
        let directory = try MeetingsDirectory.url(forMeetingID: meetingID)
        switch source {
        case "mic":
            return directory.appendingPathComponent("mic.wav")
        case "system":
            return directory.appendingPathComponent("system.wav")
        default:
            return directory.appendingPathComponent("mic.wav")
        }
    }
}

struct SamplePlaybackWindow: Equatable {
    let wavURL: URL
    let startMs: Int
    let endMs: Int
}
