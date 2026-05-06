import Foundation
import GRDB
import Testing

@testable import Execa

struct DatabaseMigrationTests {
    @Test func migrationsRunCleanly() async throws {
        let tempURL = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("execa-test-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let database = try Database.make(at: tempURL)

        let expectedTables: Set<String> = [
            "meetings",
            "speakers",
            "transcript_segments",
            "summaries",
            "prompt_templates",
            "settings",
        ]

        let actualTables: Set<String> = try await database.queue.read { db in
            let rows = try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table'"
            )
            return Set(rows)
        }
        for table in expectedTables {
            #expect(actualTables.contains(table), "missing table: \(table)")
        }

        let hasFTS: Bool = try await database.queue.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT 1 FROM sqlite_master WHERE name = 'transcript_fts' AND type = 'table'"
            ) ?? false
        }
        #expect(hasFTS, "missing FTS5 virtual table transcript_fts")

        try await database.queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO meetings (id, title, started_at, status)
                    VALUES (?, ?, ?, ?)
                """,
                arguments: ["m1", "Test meeting", 1_700_000_000_000, "live"]
            )
        }
        let meetingTitle: String? = try await database.queue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT title FROM meetings WHERE id = ?",
                arguments: ["m1"]
            )
        }
        #expect(meetingTitle == "Test meeting")
    }

    @Test func settingsRoundTrip() async throws {
        let tempURL = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("execa-test-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let database = try Database.make(at: tempURL)
        let store = SettingsStore(database: database)

        #expect(try await store.string(forKey: .displayName) == nil)
        try await store.setString("Anand", forKey: .displayName)
        #expect(try await store.string(forKey: .displayName) == "Anand")
        try await store.setString("Anand T.", forKey: .displayName)
        #expect(try await store.string(forKey: .displayName) == "Anand T.")
    }
}
