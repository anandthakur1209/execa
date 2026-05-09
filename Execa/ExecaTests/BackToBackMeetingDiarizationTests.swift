@testable import Execa
import Foundation
import GRDB
import Testing

/// Extends Phase 2's "do it twice" rule (BUG 6 lesson) into Phase 3:
/// two sequential meetings each run their own diarization swap, with
/// independent `speakers`/`transcript_segments` rows in DB. The swap
/// is keyed strictly by `meeting_id`, so the second meeting's swap
/// must not touch the first meeting's rows.
struct BackToBackMeetingDiarizationTests {
    @Test func twoSequentialMeetingsBothSwapIndependently() async throws {
        let database = try Self.tempDB()
        let settings = SettingsStore(database: database)
        try await settings.setString("Anand", forKey: .displayName)
        try await Self.insertMeeting(database, id: "m1")
        try await Self.seedStreaming(database, meetingID: "m1", text: "stream-1")
        try await Self.insertMeeting(database, id: "m2")
        try await Self.seedStreaming(database, meetingID: "m2", text: "stream-2")

        let store = await DiarizationStatusStore()
        let service = await DiarizationService(
            database: database,
            statusStore: store,
            settings: settings,
            diarize: Self.makeDiarize()
        )
        await service.runForMeeting(
            meetingID: "m1",
            micWAV: URL(fileURLWithPath: "/tmp/m1-mic.wav"),
            systemWAV: URL(fileURLWithPath: "/tmp/m1-system.wav")
        )
        await service.runForMeeting(
            meetingID: "m2",
            micWAV: URL(fileURLWithPath: "/tmp/m2-mic.wav"),
            systemWAV: URL(fileURLWithPath: "/tmp/m2-system.wav")
        )

        // Each meeting submits two files (mic.wav + system.wav), and
        // each call returns one segment — so the swap inserts two
        // rows per meeting: one tagged source=mic, one tagged
        // source=system. Both rows hold the same `batch-<meetingID>`
        // text because the mock's only key is the filename.
        #expect(try await Self.fetchTexts(database, meetingID: "m1") == ["batch-m1", "batch-m1"])
        #expect(try await Self.fetchTexts(database, meetingID: "m2") == ["batch-m2", "batch-m2"])
        try await Self.expectCompleted(store, meetingID: "m1")
        try await Self.expectCompleted(store, meetingID: "m2")
    }

    // MARK: - Helpers

    private static func tempDB() throws -> Execa.Database {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("execa-diar-back-\(UUID().uuidString).sqlite3")
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

    private static func seedStreaming(
        _ database: Execa.Database,
        meetingID: String,
        text: String
    ) async throws {
        try await database.queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO speakers (meeting_id, source, raw_speaker_id, display_label)
                VALUES (?, 'mic', 0, 'You')
                """,
                arguments: [meetingID]
            )
            let rowID = db.lastInsertedRowID
            try db.execute(
                sql: """
                INSERT INTO transcript_segments
                    (meeting_id, speaker_id, start_ms, end_ms, text, is_final, confidence)
                VALUES (?, ?, 0, 1000, ?, 1, NULL)
                """,
                arguments: [meetingID, rowID, text]
            )
        }
    }

    /// Mock diarize closure that produces a single segment whose text
    /// is keyed by the meeting ID embedded in the WAV's filename
    /// (`<meetingID>-<source>.wav`). Lets the test verify that each
    /// meeting's swap consumes only its own batch result without the
    /// closure itself knowing which meeting is currently in flight.
    private static func makeDiarize() -> DiarizationService.DiarizeFunction {
        { @Sendable wavURL, _ in
            let parts = wavURL.deletingPathExtension().lastPathComponent.split(separator: "-")
            guard let meeting = parts.first else {
                throw NSError(domain: "test", code: 0)
            }
            return SarvamBatchResult(segments: [
                .init(speakerID: 0, startMs: 0, endMs: 1000,
                      text: "batch-\(meeting)", languageCode: "en-IN")
            ])
        }
    }

    private static func fetchTexts(_ database: Execa.Database, meetingID: String) async throws -> [String] {
        try await database.queue.read { db in
            try String.fetchAll(
                db,
                sql: """
                SELECT text FROM transcript_segments
                WHERE meeting_id = ? ORDER BY start_ms
                """,
                arguments: [meetingID]
            )
        }
    }

    @MainActor
    private static func expectCompleted(_ store: DiarizationStatusStore, meetingID: String) throws {
        let status = store.status(forMeetingID: meetingID)
        if case .completed = status { return }
        Issue.record("\(meetingID) should be .completed, got \(status)")
    }
}
