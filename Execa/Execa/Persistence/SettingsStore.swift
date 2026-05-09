import Foundation
import GRDB

enum SettingsKey: String {
    case displayName = "display_name"
    case firstRunComplete = "first_run_complete"
    /// Whether `AppCoordinator.stopMeeting` auto-fires the Sarvam batch
    /// diarization pipeline. Default `true` — a missing row reads as
    /// enabled. Power users can toggle by editing the `settings` row
    /// directly in `db.sqlite3`; a Settings UI lands in Phase 5. The
    /// "Re-run diarization" button in `MeetingDetailView` is independent
    /// of this toggle and always available.
    case autoDiarization = "auto_diarization"
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

    /// Reads the `auto_diarization` setting; defaults to `true` when the
    /// row is missing (Phase 3 ships with the toggle on by default).
    /// Distinct from `bool(forKey:)` because that helper returns `false`
    /// for a missing row, which would mean "default off" and silently
    /// disable the post-meeting batch pipeline for fresh installs.
    func autoDiarization() async throws -> Bool {
        let raw = try await string(forKey: .autoDiarization)
        guard let raw else { return true }
        return raw == "true"
    }
}
