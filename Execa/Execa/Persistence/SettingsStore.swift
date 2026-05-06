import Foundation
import GRDB

enum SettingsKey: String, Sendable {
    case displayName = "display_name"
}

struct SettingsStore: Sendable {
    let database: Database

    func string(forKey key: SettingsKey) async throws -> String? {
        try await database.queue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT value FROM settings WHERE key = ?",
                arguments: [key.rawValue]
            )
        }
    }

    func setString(_ value: String, forKey key: SettingsKey) async throws {
        try await database.queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO settings (key, value) VALUES (?, ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """,
                arguments: [key.rawValue, value]
            )
        }
    }
}
