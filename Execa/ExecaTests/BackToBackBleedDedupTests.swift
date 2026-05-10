@testable import Execa
import Foundation
import GRDB
import Testing

/// Extends the cross-phase "do it twice" rule (BUG 6 lesson, applied
/// in Phase 3 BackToBackMeetingDiarizationTests) to Phase 3.5: two
/// sequential meetings with mocked bleed patterns each dedup
/// independently per `meeting_id`. The first meeting's deduped state
/// must not be re-touched by the second meeting's swap+dedup, and
/// vice versa.
struct BackToBackBleedDedupTests {
    private static func tempDB() throws -> Execa.Database {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("execa-bleed-back-\(UUID().uuidString).sqlite3")
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

    private struct StreamingSeed {
        let meetingID: String
        let source: String
        let rawSpeakerID: Int
        let label: String
        let text: String
    }

    private static func seedStreaming(_ database: Execa.Database, _ seed: StreamingSeed) async throws {
        try await database.queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO speakers (meeting_id, source, raw_speaker_id, display_label)
                VALUES (?, ?, ?, ?)
                """,
                arguments: [seed.meetingID, seed.source, seed.rawSpeakerID, seed.label]
            )
            let rowID = db.lastInsertedRowID
            try db.execute(
                sql: """
                INSERT INTO transcript_segments
                    (meeting_id, speaker_id, start_ms, end_ms, text, is_final, confidence)
                VALUES (?, ?, 0, 1000, ?, 1, NULL)
                """,
                arguments: [seed.meetingID, rowID, seed.text]
            )
        }
    }

    private static func dedupedAuditCount(
        _ database: Execa.Database,
        meetingID: String
    ) async throws -> Int {
        try await database.queue.read { db in
            try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*) FROM transcript_segments
                WHERE meeting_id = ? AND deduped_against_segment_id IS NOT NULL
                """,
                arguments: [meetingID]
            ) ?? 0
        }
    }

    private static func visibleSpeakerCount(
        _ database: Execa.Database,
        meetingID: String
    ) async throws -> Int {
        try await database.queue.read { db in
            try SpeakerQueries.visibleSpeakers(meetingID: meetingID, in: db).count
        }
    }

    @Test func twoSequentialBleedMeetingsDedupIndependently() async throws {
        let database = try Self.tempDB()
        let service = try await Self.bootstrapService(database: database)

        await service.runForMeeting(
            meetingID: "m1",
            micWAV: URL(fileURLWithPath: "/tmp/m1-mic.wav"),
            systemWAV: URL(fileURLWithPath: "/tmp/m1-system.wav")
        )
        let m1AuditCount = try await Self.dedupedAuditCount(database, meetingID: "m1")
        let m1VisibleSpeakers = try await Self.visibleSpeakerCount(database, meetingID: "m1")
        try #require(m1AuditCount == 1, "m1 mic-side should be deduped once")
        try #require(m1VisibleSpeakers == 1, "m1 should have 1 visible speaker (system only)")

        await service.runForMeeting(
            meetingID: "m2",
            micWAV: URL(fileURLWithPath: "/tmp/m2-mic.wav"),
            systemWAV: URL(fileURLWithPath: "/tmp/m2-system.wav")
        )
        let m2AuditCount = try await Self.dedupedAuditCount(database, meetingID: "m2")
        let m2VisibleSpeakers = try await Self.visibleSpeakerCount(database, meetingID: "m2")
        #expect(m2AuditCount == 1, "m2 mic-side should also be deduped once")
        #expect(m2VisibleSpeakers == 1, "m2 should have 1 visible speaker")

        let m1AuditCountPostM2 = try await Self.dedupedAuditCount(database, meetingID: "m1")
        let m1VisibleSpeakersPostM2 = try await Self.visibleSpeakerCount(database, meetingID: "m1")
        #expect(m1AuditCountPostM2 == m1AuditCount, "m1 dedup state must not change after m2 runs")
        #expect(m1VisibleSpeakersPostM2 == m1VisibleSpeakers, "m1 visible speakers must not change after m2 runs")
    }

    /// Sets up two meetings with identical streaming-time state and
    /// returns a `DiarizationService` whose mock diarize closure
    /// produces a per-meeting bleed pattern (mic and system both
    /// transcribe the same phrase keyed by the meeting ID embedded
    /// in the WAV filename).
    @MainActor
    private static func bootstrapService(database: Execa.Database) async throws -> DiarizationService {
        let settings = SettingsStore(database: database)
        try await settings.setString("Anand", forKey: .displayName)
        try await Self.insertMeeting(database, id: "m1")
        try await Self.seedStreaming(database, .init(
            meetingID: "m1", source: "mic", rawSpeakerID: 0, label: "Anand", text: "stream-mic-1"
        ))
        try await Self.seedStreaming(database, .init(
            meetingID: "m1", source: "system", rawSpeakerID: 0, label: "Remote", text: "stream-sys-1"
        ))
        try await Self.insertMeeting(database, id: "m2")
        try await Self.seedStreaming(database, .init(
            meetingID: "m2", source: "mic", rawSpeakerID: 0, label: "Anand", text: "stream-mic-2"
        ))
        try await Self.seedStreaming(database, .init(
            meetingID: "m2", source: "system", rawSpeakerID: 0, label: "Remote", text: "stream-sys-2"
        ))
        let store = DiarizationStatusStore()
        return DiarizationService(
            database: database,
            statusStore: store,
            settings: settings,
            diarize: Self.makeDiarize()
        )
    }

    /// Mock diarize closure: same phrase mic + system per meeting.
    /// Mic's text matches system's exactly, so the dedup algorithm
    /// flags every meeting's mic-side as bleed.
    private static func makeDiarize() -> DiarizationService.DiarizeFunction {
        { @Sendable wavURL, _ in
            let stem = wavURL.deletingPathExtension().lastPathComponent
            let parts = stem.split(separator: "-")
            guard let meeting = parts.first else { throw NSError(domain: "test", code: 0) }
            let phrase = meeting == "m1"
                ? "audio bleed from meeting one"
                : "audio bleed from meeting two"
            return SarvamBatchResult(segments: [
                .init(speakerID: 0, startMs: 0, endMs: 3000, text: phrase, languageCode: "en-IN")
            ])
        }
    }
}
