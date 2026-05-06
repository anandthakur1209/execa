import Foundation
import GRDB

nonisolated final class Database: @unchecked Sendable {
    let queue: DatabaseQueue

    static func make(at url: URL? = nil) throws -> Database {
        let resolved: URL
        if let url {
            resolved = url
        } else {
            resolved = try Database.defaultURL()
        }
        try FileManager.default.createDirectory(
            at: resolved.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var config = Configuration()
        config.label = "execa.main"
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
        return migrator
    }()
}
