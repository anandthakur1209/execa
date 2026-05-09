@testable import Execa
import Foundation
import GRDB
import Testing

/// Verifies the v3 migration: new columns on `speakers` + `meetings`,
/// the merge-alias FK behaviour (ON DELETE SET NULL), and that
/// foreign-key cascade deletes fire on the `speakers` →
/// `transcript_segments` chain (the post-batch swap relies on this).
struct Phase3SchemaTests {
    private static func tempDB() throws -> Execa.Database {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("execa-phase3-\(UUID().uuidString).sqlite3")
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

    @Test func v3AddsExpectedColumns() async throws {
        let database = try Self.tempDB()

        let speakerColumns: Set<String> = try await database.queue.read { db in
            let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(speakers)")
            return Set(rows.map { $0["name"] as String })
        }
        #expect(speakerColumns.contains("merged_into_speaker_id"), "missing merged_into_speaker_id on speakers")

        let meetingColumns: Set<String> = try await database.queue.read { db in
            let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(meetings)")
            return Set(rows.map { $0["name"] as String })
        }
        #expect(meetingColumns.contains("diarization_status"), "missing diarization_status on meetings")
        #expect(meetingColumns.contains("diarization_attempted_at"), "missing diarization_attempted_at on meetings")
        #expect(meetingColumns.contains("diarization_error"), "missing diarization_error on meetings")
    }

    @Test func deletingSpeakerCascadesToTranscriptSegments() async throws {
        // The post-batch swap (DiarizationService.swapInDatabase, commit
        // 4) DELETEs all old `speakers` rows for the meeting; the
        // matching `transcript_segments` rows must cascade-delete with
        // them. Requires `PRAGMA foreign_keys=ON`. GRDB enables it by
        // default; this test asserts the cascade actually fires on a
        // freshly-built DB so a future GRDB / SQLite default change
        // surfaces immediately instead of silently leaving orphan
        // segment rows.
        let database = try Self.tempDB()
        try await Self.insertMeeting(database, id: "m1")

        let speakerID: Int64 = try await database.queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO speakers (meeting_id, source, raw_speaker_id, display_label)
                VALUES (?, 'mic', 0, 'You')
                """,
                arguments: ["m1"]
            )
            return db.lastInsertedRowID
        }

        try await database.queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO transcript_segments
                    (meeting_id, speaker_id, start_ms, end_ms, text, is_final, confidence)
                VALUES (?, ?, 0, 1000, 'cascade test', 1, NULL)
                """,
                arguments: ["m1", speakerID]
            )
        }

        let preCount = try await database.queue.read { db -> Int in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM transcript_segments WHERE meeting_id = ?",
                arguments: ["m1"]
            ) ?? 0
        }
        #expect(preCount == 1)

        try await database.queue.write { db in
            try db.execute(sql: "DELETE FROM speakers WHERE id = ?", arguments: [speakerID])
        }

        let postCount = try await database.queue.read { db -> Int in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM transcript_segments WHERE meeting_id = ?",
                arguments: ["m1"]
            ) ?? 0
        }
        #expect(
            postCount == 0,
            "expected speaker delete to cascade to transcript_segments; got \(postCount) orphan rows"
        )
    }

    @Test func deletingMergeTargetSetsAliasNull() async throws {
        // ON DELETE SET NULL on `speakers.merged_into_speaker_id`: if
        // the merge target is deleted (rare; happens during the post-
        // batch swap), aliases pointing at it lose the alias instead
        // of cascading. The aliased speaker still has its own segments
        // (which DO cascade with the alias's own row, not with the
        // target's).
        let database = try Self.tempDB()
        try await Self.insertMeeting(database, id: "m1")

        let targetID: Int64 = try await database.queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO speakers (meeting_id, source, raw_speaker_id, display_label)
                VALUES (?, 'mic', 0, 'Anand')
                """,
                arguments: ["m1"]
            )
            return db.lastInsertedRowID
        }
        let aliasID: Int64 = try await database.queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO speakers
                    (meeting_id, source, raw_speaker_id, display_label, merged_into_speaker_id)
                VALUES (?, 'system', 0, 'Remote', ?)
                """,
                arguments: ["m1", targetID]
            )
            return db.lastInsertedRowID
        }

        // Sanity: alias points at target.
        let preLink: Int64? = try await database.queue.read { db in
            try Int64.fetchOne(
                db,
                sql: "SELECT merged_into_speaker_id FROM speakers WHERE id = ?",
                arguments: [aliasID]
            )
        }
        #expect(preLink == targetID)

        // Delete the target.
        try await database.queue.write { db in
            try db.execute(sql: "DELETE FROM speakers WHERE id = ?", arguments: [targetID])
        }

        // Alias row should still exist with the FK NULL'd out.
        let postLink: Int64?? = try await database.queue.read { db -> Int64?? in
            try Row.fetchOne(
                db,
                sql: "SELECT merged_into_speaker_id FROM speakers WHERE id = ?",
                arguments: [aliasID]
            ).map { $0["merged_into_speaker_id"] as Int64? }
        }
        try #require(postLink != nil, "alias row was deleted instead of having FK NULL'd")
        #expect(postLink ?? nil == nil, "alias FK should be NULL after target delete")
    }

    @Test func autoDiarizationDefaultsTrueWhenMissing() async throws {
        let database = try Self.tempDB()
        let store = SettingsStore(database: database)
        #expect(try await store.autoDiarization() == true, "default should be true when row is missing")

        try await store.setBool(false, forKey: .autoDiarization)
        #expect(try await store.autoDiarization() == false)

        try await store.setBool(true, forKey: .autoDiarization)
        #expect(try await store.autoDiarization() == true)
    }
}
