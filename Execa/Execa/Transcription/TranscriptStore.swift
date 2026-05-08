import Foundation
import GRDB

/// Live + persisted transcript state for one meeting.
///
/// Designed as `@MainActor @Observable` so SwiftUI can read `lines`
/// synchronously on the main thread (no actor-snapshot bridge). The
/// `ingest(_:source:)` entry point is `nonisolated async` — provider
/// tasks call it from arbitrary contexts; inside, DB I/O runs off-main
/// (GRDB's queue) and only state mutation hops back to MainActor.
///
/// State held:
/// - `lines`: append-mostly array of `TranscriptLine`s for the UI.
/// - `connection`: current connection state per source, drives the
///   "Connected" / "Reconnecting…" / "Transcription stopped" pill.
/// - In-memory interim map: `(source, raw_speaker_id)` → in-progress
///   line UUID. New interim text replaces the existing line; final
///   commits to DB and flips the line to `isFinal=true`.
/// - `speakerRowIDs`: cache of `(source, raw_speaker_id)` → DB id from
///   the `speakers` table. Populated lazily on first event for each
///   speaker; idempotent across restarts inside a meeting.
@MainActor
@Observable
final class TranscriptStore {
    private(set) var lines: [TranscriptLine] = []
    private(set) var connection: [PCMChunk.Source: ConnectionState] = [
        .mic: .disconnected,
        .system: .disconnected
    ]

    private let database: Database
    private var meetingID: String = ""
    private var meetingStartedAt: Date = .init()
    private var displayName: String?

    private var speakerRowIDs: [SpeakerKey: Int64] = [:]
    private var interimLineIDs: [SpeakerKey: UUID] = [:]

    enum ConnectionState: Equatable {
        case disconnected
        case connected
        case reconnecting
        case stopped
    }

    nonisolated init(database: Database) {
        self.database = database
    }

    /// Called by AppCoordinator when the meeting transitions to
    /// `.recording(meetingID:startedAt:)`. Resets in-memory state and
    /// captures the displayName the user typed in the wizard so the
    /// (mic, raw_speaker_id=0) speaker gets the right default label.
    func beginMeeting(meetingID: String, startedAt: Date, displayName: String?) {
        self.meetingID = meetingID
        meetingStartedAt = startedAt
        self.displayName = displayName?.isEmpty == false ? displayName : nil
        lines = []
        speakerRowIDs = [:]
        interimLineIDs = [:]
        connection = [.mic: .disconnected, .system: .disconnected]
    }

    /// Provider-side entry point. Nonisolated → callers don't need to
    /// hop to MainActor explicitly. DB I/O happens off-main inside the
    /// per-event handlers; state mutation runs on MainActor.
    nonisolated func ingest(_ event: TranscriptionEvent, source: PCMChunk.Source) async {
        switch event {
        case let .interim(token):
            await applyInterim(token: token, source: source)
        case let .final(token):
            await applyFinal(token: token, source: source)
        case .connected:
            await setConnection(.connected, for: source)
        case .disconnected:
            await setConnection(.reconnecting, for: source)
        case let .error(transcriptionError):
            await applyError(transcriptionError, source: source)
        }
    }

    /// Called by AppCoordinator at meeting-stop. Any pending interim
    /// segments are committed as final (so we don't lose the last
    /// utterance to the EOS race).
    func flush() async {
        let pending = interimLineIDs
        interimLineIDs = [:]
        for (key, lineID) in pending {
            guard let index = lines.firstIndex(where: { $0.id == lineID }) else { continue }
            let line = lines[index]
            lines[index].isFinal = true
            // Persist as a final segment. start_ms / end_ms come from the
            // line's already-clipped timestamp; end_ms reuses start since
            // we don't have provider-side end for the orphaned interim.
            let startMs = Int(line.timestamp * 1000)
            let speakerID = await ensureSpeakerRow(source: key.source, rawSpeakerID: key.rawID)
            guard let speakerID else { continue }
            await persistFinalSegment(
                speakerID: speakerID,
                startMs: startMs,
                endMs: startMs,
                text: line.text,
                confidence: nil
            )
        }
    }

    // MARK: - Event handlers

    private func applyInterim(token: TranscriptToken, source: PCMChunk.Source) async {
        guard let speakerID = await ensureSpeakerRow(source: source, rawSpeakerID: token.speakerID) else {
            return
        }
        let label = await fetchLabel(forSpeakerID: speakerID)
        let timestamp = relativeSeconds(token.startMs)
        let key = SpeakerKey(source: source, rawID: token.speakerID)
        if let existingID = interimLineIDs[key],
           let index = lines.firstIndex(where: { $0.id == existingID }) {
            lines[index].text = token.text
            lines[index].timestamp = timestamp
            lines[index].speakerLabel = label
        } else {
            let lineID = UUID()
            interimLineIDs[key] = lineID
            lines.append(TranscriptLine(
                id: lineID,
                speakerLabel: label,
                text: token.text,
                isFinal: false,
                timestamp: timestamp,
                source: source
            ))
        }
    }

    private func applyFinal(token: TranscriptToken, source: PCMChunk.Source) async {
        guard let speakerID = await ensureSpeakerRow(source: source, rawSpeakerID: token.speakerID) else {
            return
        }
        let label = await fetchLabel(forSpeakerID: speakerID)
        let timestamp = relativeSeconds(token.startMs)
        let key = SpeakerKey(source: source, rawID: token.speakerID)

        await persistFinalSegment(
            speakerID: speakerID,
            startMs: clippedToMeetingStart(token.startMs),
            endMs: clippedToMeetingStart(token.endMs),
            text: token.text,
            confidence: token.confidence
        )

        if let interimID = interimLineIDs.removeValue(forKey: key),
           let index = lines.firstIndex(where: { $0.id == interimID }) {
            lines[index].text = token.text
            lines[index].isFinal = true
            lines[index].timestamp = timestamp
            lines[index].speakerLabel = label
        } else {
            lines.append(TranscriptLine(
                id: UUID(),
                speakerLabel: label,
                text: token.text,
                isFinal: true,
                timestamp: timestamp,
                source: source
            ))
        }
    }

    private func setConnection(_ state: ConnectionState, for source: PCMChunk.Source) {
        connection[source] = state
    }

    private func applyError(_ error: TranscriptionError, source: PCMChunk.Source) {
        switch error {
        case .reconnectExhausted, .authFailed:
            connection[source] = .stopped
        case .other:
            connection[source] = .reconnecting
        }
    }

    // MARK: - DB helpers

    /// Returns the speakers row ID for `(meeting_id, source, raw_speaker_id)`,
    /// inserting if needed. Idempotent — repeat calls hit the in-memory
    /// cache. The display label is set at first-insert per the Phase 2
    /// label policy (DECISIONS.md 2026-05-08).
    private func ensureSpeakerRow(source: PCMChunk.Source, rawSpeakerID: Int) async -> Int64? {
        let key = SpeakerKey(source: source, rawID: rawSpeakerID)
        if let cached = speakerRowIDs[key] {
            return cached
        }
        let label = defaultLabel(source: source, rawSpeakerID: rawSpeakerID)
        let mid = meetingID
        let sourceValue = source.rawValue
        do {
            let id = try await database.queue.write { db -> Int64 in
                try db.execute(
                    sql: """
                    INSERT OR IGNORE INTO speakers (meeting_id, source, raw_speaker_id, display_label)
                    VALUES (?, ?, ?, ?)
                    """,
                    arguments: [mid, sourceValue, rawSpeakerID, label]
                )
                let row = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT id FROM speakers
                    WHERE meeting_id = ? AND source = ? AND raw_speaker_id = ?
                    """,
                    arguments: [mid, sourceValue, rawSpeakerID]
                )
                guard let row else {
                    throw TranscriptStoreError.speakerInsertFailed
                }
                return row["id"]
            }
            speakerRowIDs[key] = id
            return id
        } catch {
            return nil
        }
    }

    private func fetchLabel(forSpeakerID speakerID: Int64) async -> String {
        do {
            let label = try await database.queue.read { db -> String? in
                let row = try Row.fetchOne(
                    db,
                    sql: "SELECT display_label FROM speakers WHERE id = ?",
                    arguments: [speakerID]
                )
                return row?["display_label"]
            }
            return label ?? "Unknown"
        } catch {
            return "Unknown"
        }
    }

    private func persistFinalSegment(
        speakerID: Int64,
        startMs: Int,
        endMs: Int,
        text: String,
        confidence: Double?
    ) async {
        let mid = meetingID
        do {
            try await database.queue.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO transcript_segments
                        (meeting_id, speaker_id, start_ms, end_ms, text, is_final, confidence)
                    VALUES (?, ?, ?, ?, ?, 1, ?)
                    """,
                    arguments: [mid, speakerID, startMs, endMs, text, confidence]
                )
            }
        } catch {
            // Failures are logged-but-not-fatal in Phase 2; if the user
            // asks "where's my transcript", the in-memory `lines` still
            // has it for the current session. Phase 5's recovery path
            // is the right place to harden this.
        }
    }

    // MARK: - Pure helpers

    private func defaultLabel(source: PCMChunk.Source, rawSpeakerID: Int) -> String {
        switch source {
        case .mic:
            if rawSpeakerID == 0 {
                return displayName ?? "You"
            }
            return "In-room \(rawSpeakerID + 1)"
        case .system:
            return "Speaker \(rawSpeakerID + 1)"
        }
    }

    /// Sarvam returns timestamps relative to the start of the audio stream
    /// it received — which is also the meeting start, so on the happy path
    /// these are equivalent. We still floor at 0 to defend against
    /// negative-clipping if a provider ever sends a pre-stream-start
    /// reference.
    private func clippedToMeetingStart(_ providerMs: Int) -> Int {
        max(0, providerMs)
    }

    private func relativeSeconds(_ providerMs: Int) -> TimeInterval {
        TimeInterval(max(0, providerMs)) / 1000
    }
}

/// `(source, rawID)` key matching the `speakers` UNIQUE constraint
/// `(meeting_id, source, raw_speaker_id)`. Within a meeting, this is the
/// stable per-speaker identity.
struct SpeakerKey: Hashable {
    let source: PCMChunk.Source
    let rawID: Int
}

enum TranscriptStoreError: Error {
    case speakerInsertFailed
}
