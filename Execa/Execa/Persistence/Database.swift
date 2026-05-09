import Foundation
import GRDB

final nonisolated class Database: @unchecked Sendable {
    let queue: DatabaseQueue

    static func make(at url: URL? = nil) throws -> Database {
        let resolved: URL = if let url {
            url
        } else {
            try Database.defaultURL()
        }
        try FileManager.default.createDirectory(
            at: resolved.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var config = Configuration()
        config.label = "execa.main"
        // GRDB enables `PRAGMA foreign_keys=ON` by default — verified in
        // GRDB's source. The Phase 3 v3 migration relies on cascade
        // deletes from `speakers` to `transcript_segments` when the
        // diarization swap drops old speaker rows; that only fires when
        // foreign keys are on. A migration test (`Phase3SchemaTests`)
        // verifies the cascade actually runs on a fresh-built DB.
        let queue = try DatabaseQueue(path: resolved.path, configuration: config)
        try Database.migrator.migrate(queue)
        return Database(queue: queue)
    }

    private init(queue: DatabaseQueue) {
        self.queue = queue
    }

    private static func defaultURL() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return appSupport
            .appendingPathComponent("com.anandthakur.execa", isDirectory: true)
            .appendingPathComponent("db.sqlite3", isDirectory: false)
    }

    private static let migrator: DatabaseMigrator = {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_initial") { db in
            try db.execute(sql: """
                CREATE TABLE meetings (
                    id TEXT PRIMARY KEY,
                    title TEXT,
                    started_at INTEGER NOT NULL,
                    ended_at INTEGER,
                    audio_path TEXT,
                    status TEXT NOT NULL,
                    notes TEXT
                );
            """)
            try db.execute(sql: """
                CREATE TABLE speakers (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                    source TEXT NOT NULL,
                    raw_speaker_id INTEGER,
                    display_label TEXT NOT NULL,
                    embedding BLOB,
                    UNIQUE(meeting_id, source, raw_speaker_id)
                );
            """)
            try db.execute(sql: """
                CREATE TABLE transcript_segments (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                    speaker_id INTEGER NOT NULL REFERENCES speakers(id) ON DELETE CASCADE,
                    start_ms INTEGER NOT NULL,
                    end_ms INTEGER NOT NULL,
                    text TEXT NOT NULL,
                    is_final INTEGER NOT NULL DEFAULT 1,
                    confidence REAL
                );
            """)
            try db.execute(sql: """
                CREATE VIRTUAL TABLE transcript_fts USING fts5(
                    text, content='transcript_segments', content_rowid='id'
                );
            """)
            try db.execute(sql: """
                CREATE TABLE summaries (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                    kind TEXT NOT NULL,
                    scope_speaker_id INTEGER,
                    as_of_ts INTEGER NOT NULL,
                    model TEXT NOT NULL,
                    prompt_template_id INTEGER,
                    content_md TEXT NOT NULL
                );
            """)
            try db.execute(sql: """
                CREATE TABLE prompt_templates (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    name TEXT NOT NULL UNIQUE,
                    kind TEXT NOT NULL,
                    content TEXT NOT NULL,
                    is_default INTEGER NOT NULL DEFAULT 0,
                    updated_at INTEGER NOT NULL
                );
            """)
            try db.execute(sql: """
                CREATE TABLE settings (
                    key TEXT PRIMARY KEY,
                    value TEXT
                );
            """)
        }
        // FTS5 sync triggers for transcript_fts. The v1 contentless FTS
        // table only indexes content when these triggers fire on the
        // underlying transcript_segments table; without them, every
        // INSERT into transcript_segments leaves the FTS index empty and
        // Phase 5's history search returns nothing. Additive migration —
        // existing v1-only databases on the dev machine pick this up on
        // next launch.
        migrator.registerMigration("v2_transcript_fts_triggers") { db in
            try db.execute(sql: """
                CREATE TRIGGER transcript_fts_ai AFTER INSERT ON transcript_segments BEGIN
                    INSERT INTO transcript_fts(rowid, text) VALUES (new.id, new.text);
                END;
            """)
            try db.execute(sql: """
                CREATE TRIGGER transcript_fts_ad AFTER DELETE ON transcript_segments BEGIN
                    INSERT INTO transcript_fts(transcript_fts, rowid, text) VALUES ('delete', old.id, old.text);
                END;
            """)
            try db.execute(sql: """
                CREATE TRIGGER transcript_fts_au AFTER UPDATE ON transcript_segments BEGIN
                    INSERT INTO transcript_fts(transcript_fts, rowid, text) VALUES ('delete', old.id, old.text);
                    INSERT INTO transcript_fts(rowid, text) VALUES (new.id, new.text);
                END;
            """)
        }
        // Phase 3 schema: speaker management + diarization status.
        //   - `speakers.merged_into_speaker_id`: cross-source-capable alias
        //     FK for the merge UX (DECISIONS.md 2026-05-08 Phase 3 entry).
        //     ON DELETE SET NULL — if the merge target is deleted (rare,
        //     happens during the post-batch swap), aliases pointing at it
        //     just lose their alias instead of cascading to deletion.
        //   - `meetings.diarization_status`: NULL = `.notRequested`,
        //     `'pending'` = batch in flight, `'ok'` = swap complete,
        //     `'failed'` = batch failed (`diarization_error` carries the
        //     message).
        //   - `meetings.diarization_attempted_at`: unix ms of the most
        //     recent run (for "last attempted X ago" UI in Phase 5).
        migrator.registerMigration("v3_speaker_management_and_diarization") { db in
            try db.execute(sql: """
                ALTER TABLE speakers ADD COLUMN merged_into_speaker_id INTEGER
                    REFERENCES speakers(id) ON DELETE SET NULL;
            """)
            try db.execute(sql: """
                ALTER TABLE meetings ADD COLUMN diarization_status TEXT;
            """)
            try db.execute(sql: """
                ALTER TABLE meetings ADD COLUMN diarization_attempted_at INTEGER;
            """)
            try db.execute(sql: """
                ALTER TABLE meetings ADD COLUMN diarization_error TEXT;
            """)
        }
        return migrator
    }()
}
