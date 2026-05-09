@testable import Execa
import Foundation
import GRDB
import Testing

/// DB-driven tests for `SpeakerLabelManager`. Phase 3 commit 1 covers
/// `rename` only; merge / split tests land in commit 5 alongside
/// those operations.
struct SpeakerLabelManagerTests {
    private static func tempDB() throws -> Execa.Database {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("execa-slm-\(UUID().uuidString).sqlite3")
        return try Execa.Database.make(at: url)
    }

    private static func insertMeeting(_ database: Execa.Database, id: String) async throws {
        try await database.queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO meetings (id, title, started_at, status)
                VALUES (?, NULL, ?, 'ended')
                """,
                arguments: [id, Int64(Date().timeIntervalSince1970 * 1000)]
            )
        }
    }

    private static func insertSpeaker(
        _ database: Execa.Database,
        meetingID: String,
        source: String,
        rawSpeakerID: Int,
        label: String
    ) async throws -> Int64 {
        try await database.queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO speakers (meeting_id, source, raw_speaker_id, display_label)
                VALUES (?, ?, ?, ?)
                """,
                arguments: [meetingID, source, rawSpeakerID, label]
            )
            return db.lastInsertedRowID
        }
    }

    @Test func renameUpdatesDisplayLabel() async throws {
        let database = try Self.tempDB()
        try await Self.insertMeeting(database, id: "m1")
        let speakerID = try await Self.insertSpeaker(
            database,
            meetingID: "m1",
            source: "mic",
            rawSpeakerID: 0,
            label: "You"
        )

        let manager = SpeakerLabelManager(database: database)
        try await manager.rename(speakerID: speakerID, to: "Anand")

        let label = try await database.queue.read { db in
            try SpeakerQueries.displayLabel(speakerID: speakerID, in: db)
        }
        #expect(label == "Anand")
    }

    @Test func renameTrimsWhitespace() async throws {
        let database = try Self.tempDB()
        try await Self.insertMeeting(database, id: "m1")
        let speakerID = try await Self.insertSpeaker(
            database,
            meetingID: "m1",
            source: "mic",
            rawSpeakerID: 0,
            label: "You"
        )

        let manager = SpeakerLabelManager(database: database)
        try await manager.rename(speakerID: speakerID, to: "  Maya  \n")

        let label = try await database.queue.read { db in
            try SpeakerQueries.displayLabel(speakerID: speakerID, in: db)
        }
        #expect(label == "Maya")
    }

    @Test func renameRejectsEmptyLabel() async throws {
        let database = try Self.tempDB()
        try await Self.insertMeeting(database, id: "m1")
        let speakerID = try await Self.insertSpeaker(
            database,
            meetingID: "m1",
            source: "mic",
            rawSpeakerID: 0,
            label: "You"
        )

        let manager = SpeakerLabelManager(database: database)
        await #expect(throws: SpeakerLabelManagerError.emptyLabel) {
            try await manager.rename(speakerID: speakerID, to: "   \t\n")
        }

        // Original label preserved on rejected rename.
        let label = try await database.queue.read { db in
            try SpeakerQueries.displayLabel(speakerID: speakerID, in: db)
        }
        #expect(label == "You")
    }
}
