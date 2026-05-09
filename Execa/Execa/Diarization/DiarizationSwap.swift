import Foundation
import GRDB

// Lifted out of the `DiarizationService` actor body so the actor stays
// under the type-body-length cap and the swap pieces (which are pure
// SQL plumbing, not actor state) can be unit-tested directly inside a
// `database.queue.write` block in the future without crossing the
// actor boundary. Methods here are file-private and only callable
// from inside `DiarizationSwap.swift`'s extension on the actor — the
// outside-world public surface is still just `runForMeeting(...)`.

extension DiarizationService {
    /// Composite-key lookup used while the swap is mid-flight to
    /// translate batch-result `(source, speaker_id)` pairs back to
    /// the freshly-inserted `speakers.id`.
    fileprivate struct SpeakerKey: Hashable {
        let source: String
        let rawSpeakerID: Int
    }

    func persistStatus(meetingID: String, status: DiarizationStatus) async throws {
        let attemptedAt = Date()
        let (text, errorMessage): (String?, String?)
        switch status {
        case .notRequested:
            text = nil
            errorMessage = nil
        case .pending:
            text = "pending"
            errorMessage = nil
        case let .completed(at):
            text = "ok"
            errorMessage = nil
            try await write(
                meetingID: meetingID,
                statusText: text,
                attemptedAt: at,
                errorMessage: nil
            )
            return
        case let .failed(message):
            text = "failed"
            errorMessage = message
        }
        try await write(
            meetingID: meetingID,
            statusText: text,
            attemptedAt: attemptedAt,
            errorMessage: errorMessage
        )
    }

    private func write(
        meetingID: String,
        statusText: String?,
        attemptedAt: Date,
        errorMessage: String?
    ) async throws {
        try await database.queue.write { db in
            try db.execute(
                sql: """
                UPDATE meetings
                SET diarization_status = ?,
                    diarization_attempted_at = ?,
                    diarization_error = ?
                WHERE id = ?
                """,
                arguments: [
                    statusText,
                    Int64(attemptedAt.timeIntervalSince1970 * 1000),
                    errorMessage,
                    meetingID
                ]
            )
        }
    }

    func preBatchSegmentCount(meetingID: String) async throws -> Int {
        try await database.queue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM transcript_segments WHERE meeting_id = ?",
                arguments: [meetingID]
            ) ?? 0
        }
    }

    /// Path B's authoritative-replace swap. Atomic: the entire
    /// DELETE-then-INSERT runs in one GRDB write so a partial failure
    /// leaves the previous state intact.
    func swapInDatabase(
        meetingID: String,
        results: (mic: SarvamBatchResult, system: SarvamBatchResult),
        displayName: String
    ) async throws {
        try await database.queue.write { db in
            // 1. Capture the mic-0 rename if the user changed it
            //    mid-meeting (Decision 17 / Revision 2). Empty or
            //    matching displayName means no real rename happened.
            let preservedMicZeroLabel = try Self.fetchPreservedMicZeroLabel(
                meetingID: meetingID,
                displayName: displayName,
                in: db
            )

            // 2. DELETE old speakers; cascade nukes their segments.
            try db.execute(
                sql: "DELETE FROM speakers WHERE meeting_id = ?",
                arguments: [meetingID]
            )

            // 3. INSERT new speakers with Path B defaults.
            var speakerIDMap: [SpeakerKey: Int64] = [:]
            try Self.insertSpeakers(
                meetingID: meetingID,
                results: results,
                displayName: displayName,
                map: &speakerIDMap,
                in: db
            )

            // 4. Reapply the preserved mic-0 rename, if any.
            if let preservedMicZeroLabel,
               let micZeroID = speakerIDMap[SpeakerKey(source: "mic", rawSpeakerID: 0)] {
                try db.execute(
                    sql: "UPDATE speakers SET display_label = ? WHERE id = ?",
                    arguments: [preservedMicZeroLabel, micZeroID]
                )
            }

            // 5. INSERT new transcript_segments via the speaker map.
            try Self.insertSegments(
                meetingID: meetingID,
                source: "mic",
                segments: results.mic.segments,
                map: speakerIDMap,
                in: db
            )
            try Self.insertSegments(
                meetingID: meetingID,
                source: "system",
                segments: results.system.segments,
                map: speakerIDMap,
                in: db
            )
        }
    }

    // MARK: - Static SQL helpers (run inside GRDB's write closure)

    fileprivate static func fetchPreservedMicZeroLabel(
        meetingID: String,
        displayName: String,
        in db: GRDB.Database
    ) throws -> String? {
        let label: String? = try String.fetchOne(
            db,
            sql: """
            SELECT display_label FROM speakers
            WHERE meeting_id = ? AND source = 'mic' AND raw_speaker_id = 0
            """,
            arguments: [meetingID]
        )
        guard let label, label != displayName, !label.isEmpty else { return nil }
        return label
    }

    fileprivate static func insertSpeakers(
        meetingID: String,
        results: (mic: SarvamBatchResult, system: SarvamBatchResult),
        displayName: String,
        map: inout [SpeakerKey: Int64],
        in db: GRDB.Database
    ) throws {
        let micIDs = Set(results.mic.segments.map(\.speakerID)).sorted()
        let systemIDs = Set(results.system.segments.map(\.speakerID)).sorted()
        for rawID in micIDs {
            let label = micLabel(rawSpeakerID: rawID, displayName: displayName)
            let speakerRowID = try insertSpeakerRow(
                meetingID: meetingID,
                source: "mic",
                rawSpeakerID: rawID,
                label: label,
                in: db
            )
            map[SpeakerKey(source: "mic", rawSpeakerID: rawID)] = speakerRowID
        }
        for rawID in systemIDs {
            let label = systemLabel(rawSpeakerID: rawID)
            let speakerRowID = try insertSpeakerRow(
                meetingID: meetingID,
                source: "system",
                rawSpeakerID: rawID,
                label: label,
                in: db
            )
            map[SpeakerKey(source: "system", rawSpeakerID: rawID)] = speakerRowID
        }
    }

    fileprivate static func insertSpeakerRow(
        meetingID: String,
        source: String,
        rawSpeakerID: Int,
        label: String,
        in db: GRDB.Database
    ) throws -> Int64 {
        try db.execute(
            sql: """
            INSERT INTO speakers (meeting_id, source, raw_speaker_id, display_label)
            VALUES (?, ?, ?, ?)
            """,
            arguments: [meetingID, source, rawSpeakerID, label]
        )
        return db.lastInsertedRowID
    }

    fileprivate static func insertSegments(
        meetingID: String,
        source: String,
        segments: [SarvamBatchResult.BatchSegment],
        map: [SpeakerKey: Int64],
        in db: GRDB.Database
    ) throws {
        for segment in segments {
            let key = SpeakerKey(source: source, rawSpeakerID: segment.speakerID)
            guard let speakerRowID = map[key] else { continue }
            try db.execute(
                sql: """
                INSERT INTO transcript_segments
                    (meeting_id, speaker_id, start_ms, end_ms, text, is_final, confidence)
                VALUES (?, ?, ?, ?, ?, 1, NULL)
                """,
                arguments: [
                    meetingID,
                    speakerRowID,
                    segment.startMs,
                    segment.endMs,
                    segment.text
                ]
            )
        }
    }

    /// Path B mic default. `(mic, 0)` is the user, so it gets
    /// `displayName`; higher IDs are additional in-room voices.
    fileprivate static func micLabel(rawSpeakerID: Int, displayName: String) -> String {
        rawSpeakerID == 0 ? displayName : "In-room \(rawSpeakerID + 1)"
    }

    /// Path B system default. The 0-indexed cluster is `Speaker 1` so
    /// the human-facing numbering starts at 1.
    fileprivate static func systemLabel(rawSpeakerID: Int) -> String {
        "Speaker \(rawSpeakerID + 1)"
    }
}
