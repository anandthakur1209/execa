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
    /// Whether `DiarizationService.runForMeeting` runs the speaker
    /// bleed-through dedup pass after `swapInDatabase` succeeds.
    /// Default `true` — a missing row reads as enabled. Power users
    /// can disable by editing the row directly; a Settings UI lands in
    /// Phase 5. Disabling is the recovery path for the rare device-
    /// owner-repeats-system case (DECISIONS.md Phase 3.5 entry).
    case autoSpeakerBleedDedup = "auto_speaker_bleed_dedup"
    /// Which dedup algorithm `SpeakerBleedDeduper` runs when dedup is
    /// enabled. `"v1"` = Phase 3.5 Jaccard pairwise; `"v2"` =
    /// Phase 3.5b containment + Porter-light stemming + concatenation
    /// pre-pass + cross-validation post-pass. Default `.v1` in commit
    /// (a) of the Phase 3.5b plan (algorithm-version plumbing only);
    /// flipped to `.v2` in commit (b) once the v2 core lands.
    /// Orthogonal to `autoSpeakerBleedDedup`: that toggles WHETHER
    /// dedup runs at all; this picks WHICH algorithm.
    case bleedDedupAlgorithmVersion = "bleed_dedup_algorithm_version"
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

    /// Reads the `auto_speaker_bleed_dedup` setting; defaults to `true`
    /// when the row is missing (Phase 3.5 ships with dedup on by
    /// default). Same default-on semantics as `autoDiarization` —
    /// fresh installs get the full pipeline.
    func autoSpeakerBleedDedup() async throws -> Bool {
        let raw = try await string(forKey: .autoSpeakerBleedDedup)
        guard let raw else { return true }
        return raw == "true"
    }

    /// Reads the `bleed_dedup_algorithm_version` setting; defaults to
    /// `.v2` (Phase 3.5b — containment + Porter-light stemming). v1 is
    /// retained as a flag-fallback so users can revert with a direct
    /// DB edit if v2 over-dedupes in real meetings. Unknown strings
    /// fall back to the default to defend against typos when the user
    /// edits the row directly.
    func bleedDedupAlgorithmVersion() async throws -> BleedDedupAlgorithmVersion {
        let raw = try await string(forKey: .bleedDedupAlgorithmVersion)
        guard let raw else { return .v2 }
        return BleedDedupAlgorithmVersion(rawValue: raw) ?? .v2
    }
}
