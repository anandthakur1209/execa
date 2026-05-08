@testable import Execa
import Foundation
import GRDB
import Testing

@MainActor
struct TranscriptStoreTests {
    private static func tempDB() throws -> Execa.Database {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("execa-store-\(UUID().uuidString).sqlite3")
        return try Execa.Database.make(at: url)
    }

    private static func token(
        speakerID: Int = 0,
        text: String,
        startMs: Int = 0,
        endMs: Int = 1000
    ) -> TranscriptToken {
        TranscriptToken(
            startMs: startMs,
            endMs: endMs,
            speakerID: speakerID,
            text: text,
            confidence: 0.9,
            language: nil
        )
    }

    @Test func interimDoesNotWriteDBRow() async throws {
        let database = try Self.tempDB()
        let meetingID = ULID.generate()
        try await Self.insertMeetingRow(database, id: meetingID)

        let store = TranscriptStore(database: database)
        store.beginMeeting(meetingID: meetingID, startedAt: Date(), displayName: "Anand")
        await store.ingest(.interim(Self.token(text: "hel...")), source: .mic)

        // In-memory line shows up.
        #expect(store.lines.count == 1)
        #expect(store.lines[0].isFinal == false)
        // No DB row.
        let rowCount = try await Self.transcriptRowCount(database, meetingID: meetingID)
        #expect(rowCount == 0)
    }

    @Test func finalWritesExactlyOneDBRowAndFTSReturnsHit() async throws {
        let database = try Self.tempDB()
        let meetingID = ULID.generate()
        try await Self.insertMeetingRow(database, id: meetingID)

        let store = TranscriptStore(database: database)
        store.beginMeeting(meetingID: meetingID, startedAt: Date(), displayName: "Anand")
        await store.ingest(
            .final(Self.token(text: "hello phase 2 transcription test")),
            source: .mic
        )

        let rowCount = try await Self.transcriptRowCount(database, meetingID: meetingID)
        #expect(rowCount == 1)

        // FTS round-trip — relies on the v2 trigger lighting up.
        let ftsHits = try await database.queue.read { db in
            try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*) FROM transcript_fts WHERE transcript_fts MATCH ?
                """,
                arguments: ["phase"]
            ) ?? 0
        }
        #expect(ftsHits == 1, "expected FTS to find the inserted row, got \(ftsHits)")
    }

    @Test func interimToFinalReplacesLineInPlace() async throws {
        let database = try Self.tempDB()
        let meetingID = ULID.generate()
        try await Self.insertMeetingRow(database, id: meetingID)

        let store = TranscriptStore(database: database)
        store.beginMeeting(meetingID: meetingID, startedAt: Date(), displayName: "Anand")

        await store.ingest(.interim(Self.token(text: "hel...")), source: .mic)
        await store.ingest(.interim(Self.token(text: "hello wor...")), source: .mic)
        await store.ingest(.final(Self.token(text: "hello world")), source: .mic)

        #expect(store.lines.count == 1, "interim then final should not create extra lines")
        #expect(store.lines[0].text == "hello world")
        #expect(store.lines[0].isFinal == true)
    }

    @Test func phase2StreamingMicCollapsesToDisplayName() async throws {
        // Phase 2 (Path B) regression gate: Sarvam streaming STT does not
        // diarize, so every mic event arrives with raw_speaker_id=0. The
        // DB must contain exactly one mic-side speakers row labeled with
        // the user's displayName, regardless of how many segments come in.
        let database = try Self.tempDB()
        let meetingID = ULID.generate()
        try await Self.insertMeetingRow(database, id: meetingID)

        let store = TranscriptStore(database: database)
        store.beginMeeting(meetingID: meetingID, startedAt: Date(), displayName: "Anand")

        for index in 0 ..< 5 {
            await store.ingest(
                .final(Self.token(speakerID: 0, text: "turn \(index)", startMs: index * 1000)),
                source: .mic
            )
        }

        let labels = try await database.queue.read { db -> [String] in
            try Row.fetchAll(
                db,
                sql: """
                SELECT display_label FROM speakers
                WHERE meeting_id = ? AND source = 'mic'
                ORDER BY raw_speaker_id ASC
                """,
                arguments: [meetingID]
            ).map { $0["display_label"] }
        }
        #expect(labels == ["Anand"], "Phase 2 streaming mic must collapse to one label, got \(labels)")
    }

    @Test func phase2StreamingSystemCollapsesToRemote() async throws {
        // Same Path-B logic for the system stream: every event arrives with
        // raw_speaker_id=0 under Sarvam streaming, so the DB must contain
        // exactly one system-side speakers row labeled "Remote".
        let database = try Self.tempDB()
        let meetingID = ULID.generate()
        try await Self.insertMeetingRow(database, id: meetingID)

        let store = TranscriptStore(database: database)
        store.beginMeeting(meetingID: meetingID, startedAt: Date(), displayName: "Anand")

        for index in 0 ..< 5 {
            await store.ingest(
                .final(Self.token(speakerID: 0, text: "remote \(index)", startMs: index * 1000)),
                source: .system
            )
        }

        let labels = try await database.queue.read { db -> [String] in
            try Row.fetchAll(
                db,
                sql: """
                SELECT display_label FROM speakers
                WHERE meeting_id = ? AND source = 'system'
                ORDER BY raw_speaker_id ASC
                """,
                arguments: [meetingID]
            ).map { $0["display_label"] }
        }
        #expect(labels == ["Remote"], "Phase 2 streaming system must collapse to one 'Remote' label, got \(labels)")
    }

    @Test func batchBackfillMultipleMicSpeakersGetInRoomDefaults() async throws {
        // Phase 3 forward-looking gate: when the post-hoc Sarvam batch API
        // produces multiple mic speaker IDs, the (mic, 0) row already
        // labeled with displayName stays put, and additional mic IDs get
        // "In-room 2" / "In-room 3" defaults. The Phase 3 rename UI
        // overwrites these defaults, but until then the code path needs to
        // produce sensible names.
        let database = try Self.tempDB()
        let meetingID = ULID.generate()
        try await Self.insertMeetingRow(database, id: meetingID)

        let store = TranscriptStore(database: database)
        store.beginMeeting(meetingID: meetingID, startedAt: Date(), displayName: "Anand")

        await store.ingest(.final(Self.token(speakerID: 0, text: "I'll start.")), source: .mic)
        await store.ingest(.final(Self.token(speakerID: 1, text: "Adding from this side.")), source: .mic)
        await store.ingest(.final(Self.token(speakerID: 2, text: "Last in-room comment.")), source: .mic)

        let labels = try await database.queue.read { db -> [String] in
            try Row.fetchAll(
                db,
                sql: """
                SELECT display_label FROM speakers
                WHERE meeting_id = ? AND source = 'mic'
                ORDER BY raw_speaker_id ASC
                """,
                arguments: [meetingID]
            ).map { $0["display_label"] }
        }
        #expect(labels == ["Anand", "In-room 2", "In-room 3"], "got \(labels)")
    }

    @Test func batchBackfillMultipleSystemSpeakersGetSpeakerDefaults() async throws {
        // Phase 3 forward-looking gate: post-hoc batch produces multiple
        // system speaker IDs; (system, 0) keeps "Remote" from streaming;
        // additional IDs get "Speaker 2" / "Speaker 3" defaults.
        let database = try Self.tempDB()
        let meetingID = ULID.generate()
        try await Self.insertMeetingRow(database, id: meetingID)

        let store = TranscriptStore(database: database)
        store.beginMeeting(meetingID: meetingID, startedAt: Date(), displayName: "Anand")

        await store.ingest(.final(Self.token(speakerID: 0, text: "first remote")), source: .system)
        await store.ingest(.final(Self.token(speakerID: 1, text: "second remote")), source: .system)

        let labels = try await database.queue.read { db -> [String] in
            try Row.fetchAll(
                db,
                sql: """
                SELECT display_label FROM speakers
                WHERE meeting_id = ? AND source = 'system'
                ORDER BY raw_speaker_id ASC
                """,
                arguments: [meetingID]
            ).map { $0["display_label"] }
        }
        #expect(labels == ["Remote", "Speaker 2"])
    }

    @Test func displayNameFallsBackToYouWhenAbsent() async throws {
        let database = try Self.tempDB()
        let meetingID = ULID.generate()
        try await Self.insertMeetingRow(database, id: meetingID)

        let store = TranscriptStore(database: database)
        // No displayName provided.
        store.beginMeeting(meetingID: meetingID, startedAt: Date(), displayName: nil)
        await store.ingest(.final(Self.token(text: "hi")), source: .mic)

        let label = try await database.queue.read { db -> String? in
            try Row.fetchOne(
                db,
                sql: """
                SELECT display_label FROM speakers
                WHERE meeting_id = ? AND source = 'mic' AND raw_speaker_id = 0
                """,
                arguments: [meetingID]
            )?["display_label"]
        }
        #expect(label == "You")
    }

    @Test func speakerInsertionIsIdempotent() async throws {
        let database = try Self.tempDB()
        let meetingID = ULID.generate()
        try await Self.insertMeetingRow(database, id: meetingID)

        let store = TranscriptStore(database: database)
        store.beginMeeting(meetingID: meetingID, startedAt: Date(), displayName: "Anand")

        // Same (mic, raw_speaker_id=0) emitted ten times.
        for index in 0 ..< 10 {
            await store.ingest(.final(Self.token(text: "turn \(index)", startMs: index * 1000)), source: .mic)
        }

        let speakerCount = try await database.queue.read { db -> Int in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM speakers WHERE meeting_id = ?",
                arguments: [meetingID]
            ) ?? 0
        }
        #expect(speakerCount == 1, "expected one speakers row, got \(speakerCount)")
    }

    @Test func flushCommitsPendingInterimAsFinal() async throws {
        let database = try Self.tempDB()
        let meetingID = ULID.generate()
        try await Self.insertMeetingRow(database, id: meetingID)

        let store = TranscriptStore(database: database)
        store.beginMeeting(meetingID: meetingID, startedAt: Date(), displayName: "Anand")
        await store.ingest(.interim(Self.token(text: "the last word was lost...")), source: .mic)
        await store.flush()

        let rowCount = try await Self.transcriptRowCount(database, meetingID: meetingID)
        #expect(rowCount == 1, "flush should turn a pending interim into a final DB row")
        #expect(store.lines.last?.isFinal == true)
    }

    // MARK: - Helpers

    private static func insertMeetingRow(_ database: Execa.Database, id: String) async throws {
        try await database.queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO meetings (id, title, started_at, status)
                VALUES (?, NULL, ?, 'live')
                """,
                arguments: [id, Int64(Date().timeIntervalSince1970 * 1000)]
            )
        }
    }

    private static func transcriptRowCount(_ database: Execa.Database, meetingID: String) async throws -> Int {
        try await database.queue.read { db -> Int in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM transcript_segments WHERE meeting_id = ?",
                arguments: [meetingID]
            ) ?? 0
        }
    }
}
