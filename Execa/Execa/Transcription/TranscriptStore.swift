import Foundation
import GRDB

/// Live + persisted transcript state for one meeting. `@MainActor
/// @Observable` so SwiftUI reads `lines` synchronously; `ingest` is
/// `nonisolated async` so providers call it from any context (DB I/O
/// off-main, state mutation MainActor). Holds `lines`, `connection`,
/// the in-memory interim map keyed by `(source, raw_speaker_id)`, and
/// the `speakerRowIDs` lazy cache.
@MainActor
@Observable
final class TranscriptStore {
    private(set) var lines: [TranscriptLine] = []
    private(set) var connection: [PCMChunk.Source: ConnectionState] = [
        .mic: .disconnected,
        .system: .disconnected
    ]

    /// Live talk-time per `speakers.id` row, in seconds. SpeakerSidebar
    /// reads this; post-meeting MeetingDetailView uses the SQL
    /// equivalent in `SpeakerQueries.talkTimeAggregated`. Keyed by raw
    /// `speakers.id` (merges happen post-batch only).
    private(set) var talkTimeBySpeaker: [Int64: TimeInterval] = [:]

    private let database: Database
    /// Clock used to compute wall-clock-since-meeting-start when a
    /// streaming provider can't supply absolute timestamps (Sarvam).
    /// Injected so tests can pass a fixed-value closure for
    /// deterministic assertions; production uses `Date.init`.
    private let clock: () -> Date
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

    nonisolated init(database: Database, clock: @escaping () -> Date = Date.init) {
        self.database = database
        self.clock = clock
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
        talkTimeBySpeaker = [:]
        connection = [.mic: .disconnected, .system: .disconnected]
    }

    /// Provider-side entry point. Nonisolated → callers don't need to
    /// hop to MainActor explicitly. DB I/O happens off-main inside the
    /// per-event handlers; state mutation runs on MainActor.
    ///
    /// `providesAbsoluteTimestamps` reflects the source provider's
    /// `TranscriptionProvider.providesAbsoluteTimestamps` requirement.
    /// The default `true` keeps existing direct-driven tests working
    /// without changes; `TranscriptionService` reads each provider's
    /// flag at bridge-start and passes it through here so
    /// `applyFinal` can pick the right timestamp arithmetic per source.
    nonisolated func ingest(
        _ event: TranscriptionEvent,
        source: PCMChunk.Source,
        providesAbsoluteTimestamps: Bool = true
    ) async {
        switch event {
        case let .interim(token):
            await applyInterim(token: token, source: source)
        case let .final(token):
            await applyFinal(
                token: token,
                source: source,
                providesAbsoluteTimestamps: providesAbsoluteTimestamps
            )
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
            lines[index].databaseSpeakerID = speakerID
        } else {
            let lineID = UUID()
            interimLineIDs[key] = lineID
            lines.append(TranscriptLine(
                id: lineID,
                speakerLabel: label,
                text: token.text,
                isFinal: false,
                timestamp: timestamp,
                source: source,
                databaseSegmentID: nil,
                databaseSpeakerID: speakerID
            ))
        }
    }

    /// Commits a finalized event to in-memory `lines` + the DB
    /// `transcript_segments` table.
    ///
    /// Timestamp arithmetic depends on the source provider's
    /// `providesAbsoluteTimestamps` flag (see
    /// `TranscriptionProvider`):
    /// - `true`: trust `token.startMs` / `token.endMs` directly (they
    ///   are absolute positions in the audio stream the provider saw,
    ///   which here also equals the meeting start since execa sends
    ///   audio from start-of-meeting onward).
    /// - `false`: the provider couldn't supply absolute timestamps and
    ///   put the segment duration in `token.endMs`. Use the injected
    ///   clock's wall-clock-since-meeting-start as the segment end;
    ///   subtract the duration for the start.
    private func applyFinal(
        token: TranscriptToken,
        source: PCMChunk.Source,
        providesAbsoluteTimestamps: Bool
    ) async {
        guard let speakerID = await ensureSpeakerRow(source: source, rawSpeakerID: token.speakerID) else {
            return
        }
        let label = await fetchLabel(forSpeakerID: speakerID)
        let key = SpeakerKey(source: source, rawID: token.speakerID)

        let computedStart: TimeInterval
        let computedEnd: TimeInterval
        if providesAbsoluteTimestamps {
            computedStart = TimeInterval(max(0, token.startMs)) / 1000
            computedEnd = TimeInterval(max(0, token.endMs)) / 1000
        } else {
            // Streaming-provider wall-clock fallback. token.endMs
            // carries the segment duration in ms (Sarvam's wire
            // format). Use elapsed since meeting start as the
            // segment's end position; subtract duration for the start.
            //
            // INTENTIONAL CLAMP: max(0, ...) below truncates segment
            // duration for utterances that finalize very close to
            // meeting start (elapsed < duration — happens if the
            // provider emits a final mid-first-utterance, before
            // meetingStartedAt + duration_ms wall-clock). We accept
            // the truncation rather than reporting negative start_ms;
            // it's at most a couple-second cosmetic distortion on the
            // very first line and only when the user starts speaking
            // before the socket connects. NOT a bug — leave the
            // clamp as-is.
            let durationSeconds = TimeInterval(max(0, token.endMs)) / 1000
            computedEnd = max(0, clock().timeIntervalSince(meetingStartedAt))
            computedStart = max(0, computedEnd - durationSeconds)
        }
        let timestamp = computedStart

        let dbSegmentID = await persistFinalSegment(
            speakerID: speakerID,
            startMs: Int(computedStart * 1000),
            endMs: Int(computedEnd * 1000),
            text: token.text,
            confidence: token.confidence
        )

        talkTimeBySpeaker[speakerID, default: 0] += max(0, computedEnd - computedStart)

        if let interimID = interimLineIDs.removeValue(forKey: key),
           let index = lines.firstIndex(where: { $0.id == interimID }) {
            lines[index].text = token.text
            lines[index].isFinal = true
            lines[index].timestamp = timestamp
            lines[index].speakerLabel = label
            lines[index].databaseSegmentID = dbSegmentID
            lines[index].databaseSpeakerID = speakerID
            return
        }
        lines.append(TranscriptLine(
            id: UUID(),
            speakerLabel: label,
            text: token.text,
            isFinal: true,
            timestamp: timestamp,
            source: source,
            databaseSegmentID: dbSegmentID,
            databaseSpeakerID: speakerID
        ))
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

    @discardableResult
    private func persistFinalSegment(
        speakerID: Int64,
        startMs: Int,
        endMs: Int,
        text: String,
        confidence: Double?
    ) async -> Int64? {
        let mid = meetingID
        do {
            return try await database.queue.write { db -> Int64 in
                try db.execute(
                    sql: """
                    INSERT INTO transcript_segments
                        (meeting_id, speaker_id, start_ms, end_ms, text, is_final, confidence)
                    VALUES (?, ?, ?, ?, ?, 1, ?)
                    """,
                    arguments: [mid, speakerID, startMs, endMs, text, confidence]
                )
                return db.lastInsertedRowID
            }
        } catch {
            // Failures are logged-but-not-fatal in Phase 2; if the user
            // asks "where's my transcript", the in-memory `lines` still
            // has it for the current session. Phase 5's recovery path
            // is the right place to harden this.
            return nil
        }
    }

    // MARK: - Pure helpers

    private func defaultLabel(source: PCMChunk.Source, rawSpeakerID: Int) -> String {
        TranscriptDefaultLabel.label(
            source: source,
            rawSpeakerID: rawSpeakerID,
            displayName: displayName
        )
    }

    private func relativeSeconds(_ providerMs: Int) -> TimeInterval {
        TimeInterval.relativeSeconds(providerMs: providerMs)
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

// MARK: - Label propagation (BUG 7)

//
// Lifted to a same-file extension so the methods don't count toward
// the type-body-length cap. Without these, past transcript turns
// kept their stale captured `speakerLabel` until the next `.final`
// event arrived. Called by `AppCoordinator`'s rename/merge/split
// wrappers after the DB write succeeds.

extension TranscriptStore {
    func applyRename(speakerID: Int64, newLabel: String) {
        for index in lines.indices where lines[index].databaseSpeakerID == speakerID {
            lines[index].speakerLabel = newLabel
        }
    }

    func applyMerge(sourceSpeakerID: Int64, targetLabel: String) {
        for index in lines.indices where lines[index].databaseSpeakerID == sourceSpeakerID {
            lines[index].speakerLabel = targetLabel
        }
    }

    func applySplit(segmentID: Int64, newSpeakerID: Int64, newLabel: String) {
        for index in lines.indices where lines[index].databaseSegmentID == segmentID {
            lines[index].databaseSpeakerID = newSpeakerID
            lines[index].speakerLabel = newLabel
        }
    }
}
