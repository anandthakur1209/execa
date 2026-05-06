import Foundation
import GRDB

enum SettingsKey: String {
    case displayName = "display_name"
    case firstRunComplete = "first_run_complete"
}

struct SettingsStore {
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

    func bool(forKey key: SettingsKey) async throws -> Bool {
        let raw = try await string(forKey: key)
        return raw == "true"
    }

    func setBool(_ value: Bool, forKey key: SettingsKey) async throws {
        try await setString(value ? "true" : "false", forKey: key)
    }
}
