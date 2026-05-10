@testable import Execa
import Foundation
import GRDB
import Testing

/// Verifies the v4 migration: the `deduped_against_segment_id` column
/// on `transcript_segments`, the ON DELETE SET NULL behaviour on the
/// audit FK, and the `auto_speaker_bleed_dedup` settings default.
struct Phase35SchemaTests {
    private static func tempDB() throws -> Execa.Database {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("execa-phase35-\(UUID().uuidString).sqlite3")
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

    private static func insertSegment(
        _ database: Execa.Database,
        meetingID: String,
        speakerID: Int64,
        text: String
    ) async throws -> Int64 {
        try await database.queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO transcript_segments
                    (meeting_id, speaker_id, start_ms, end_ms, text, is_final, confidence)
                VALUES (?, ?, 0, 1000, ?, 1, NULL)
                """,
                arguments: [meetingID, speakerID, text]
            )
            return db.lastInsertedRowID
        }
    }

    @Test func v4AddsDedupedAgainstSegmentColumn() async throws {
        let database = try Self.tempDB()

        let segmentColumns: Set<String> = try await database.queue.read { db in
            let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(transcript_segments)")
            return Set(rows.map { $0["name"] as String })
        }
        #expect(
            segmentColumns.contains("deduped_against_segment_id"),
            "missing deduped_against_segment_id on transcript_segments"
        )
    }

    @Test func dedupedAgainstSegmentSetNullOnTargetDelete() async throws {
        // The audit FK is `ON DELETE SET NULL`: if the surviving
        // (system-side) target is deleted, the deduped (mic-side) row
        // stays — but its audit pointer is NULLed rather than
        // cascading further. Verifies `PRAGMA foreign_keys=ON` and
        // the FK clause are both wired correctly.
        let database = try Self.tempDB()
        try await Self.insertMeeting(database, id: "m1")
        let micSpeakerID = try await Self.insertSpeaker(
            database, meetingID: "m1", source: "mic", rawSpeakerID: 0, label: "You"
        )
        let systemSpeakerID = try await Self.insertSpeaker(
            database, meetingID: "m1", source: "system", rawSpeakerID: 0, label: "Remote"
        )
        let micSegmentID = try await Self.insertSegment(
            database, meetingID: "m1", speakerID: micSpeakerID, text: "bleed"
        )
        let systemSegmentID = try await Self.insertSegment(
            database, meetingID: "m1", speakerID: systemSpeakerID, text: "bleed"
        )

        // Soft-delete the mic-side segment by pointing its audit FK
        // at the system-side segment.
        try await database.queue.write { db in
            try db.execute(
                sql: """
                UPDATE transcript_segments
                SET deduped_against_segment_id = ?
                WHERE id = ?
                """,
                arguments: [systemSegmentID, micSegmentID]
            )
        }

        let preLink: Int64? = try await database.queue.read { db in
            try Int64.fetchOne(
                db,
                sql: "SELECT deduped_against_segment_id FROM transcript_segments WHERE id = ?",
                arguments: [micSegmentID]
            )
        }
        #expect(preLink == systemSegmentID)

        // Now delete the system-side surviving segment. The mic-side
        // soft-deleted row should still exist with its audit FK
        // NULL'd by the ON DELETE SET NULL clause.
        try await database.queue.write { db in
            try db.execute(
                sql: "DELETE FROM transcript_segments WHERE id = ?",
                arguments: [systemSegmentID]
            )
        }

        let postLink: Int64?? = try await database.queue.read { db -> Int64?? in
            try Row.fetchOne(
                db,
                sql: "SELECT deduped_against_segment_id FROM transcript_segments WHERE id = ?",
                arguments: [micSegmentID]
            ).map { $0["deduped_against_segment_id"] as Int64? }
        }
        try #require(postLink != nil, "mic-side row was deleted instead of having audit FK NULL'd")
        #expect(postLink ?? nil == nil, "audit FK should be NULL after target delete")
    }

    @Test func autoSpeakerBleedDedupDefaultsTrueWhenMissing() async throws {
        let database = try Self.tempDB()
        let store = SettingsStore(database: database)
        #expect(try await store.autoSpeakerBleedDedup() == true, "default should be true when row is missing")

        try await store.setBool(false, forKey: .autoSpeakerBleedDedup)
        #expect(try await store.autoSpeakerBleedDedup() == false)

        try await store.setBool(true, forKey: .autoSpeakerBleedDedup)
        #expect(try await store.autoSpeakerBleedDedup() == true)
    }
}
