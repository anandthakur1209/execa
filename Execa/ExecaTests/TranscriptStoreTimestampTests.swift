@testable import Execa
import Foundation
import GRDB
import Testing

/// Timestamp-arithmetic gates for `TranscriptStore.applyFinal`. Split out
/// of `TranscriptStoreTests` because that struct hit SwiftLint's 250-line
/// type-body cap; this is the natural seam (timestamps are a distinct
/// concern from labels / interim / FTS).
@MainActor
struct TranscriptStoreTimestampTests {
    private static func tempDB() throws -> Execa.Database {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("execa-store-ts-\(UUID().uuidString).sqlite3")
        return try Execa.Database.make(at: url)
    }

    private static func insertMeetingRow(_ database: Execa.Database, id: String) async throws {
        try await database.queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO meetings (id, title, started_at, status)
                VALUES (?, NULL, ?, 'live')
                """,
                arguments: [id, Int64(Date().timeIntervalSince1970 * 1000)]
            )
        }
    }

    @Test func wallClockFallbackForStreamingProvider() async throws {
        // BUG 2 regression gate: when the source provider can't supply
        // absolute timestamps (Sarvam streaming, today), TranscriptStore
        // must derive segment timestamps from a wall-clock relative to
        // the meeting start — not faithfully record a 0-sentinel
        // start_ms. Uses an injected fixed clock so the math is
        // deterministic across CI cadences.
        let database = try Self.tempDB()
        let meetingID = ULID.generate()
        try await Self.insertMeetingRow(database, id: meetingID)

        let startedAt = Date(timeIntervalSince1970: 1_000_000)
        let fixedNow = startedAt.addingTimeInterval(30) // pretend 30 s elapsed
        let store = TranscriptStore(database: database, clock: { fixedNow })
        store.beginMeeting(meetingID: meetingID, startedAt: startedAt, displayName: "Anand")

        // Streaming-provider shape: startMs=0, endMs holds the
        // segment duration in ms (Sarvam's wire format).
        let token = TranscriptToken(
            startMs: 0,
            endMs: 3000, // 3 s utterance
            speakerID: 0,
            text: "wall-clock test",
            confidence: nil,
            language: nil
        )
        await store.ingest(.final(token), source: .mic, providesAbsoluteTimestamps: false)

        let line = try #require(store.lines.first)
        // Expected: end=30 s (fixedNow - startedAt), start=27 s (end-3 s).
        #expect(line.timestamp == 27.0, "got \(line.timestamp)")

        let segments = try await database.queue.read { db -> [(Int, Int)] in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT start_ms, end_ms FROM transcript_segments
                WHERE meeting_id = ?
                """,
                arguments: [meetingID]
            )
            return rows.map { row -> (Int, Int) in
                let startMs: Int64 = row["start_ms"]
                let endMs: Int64 = row["end_ms"]
                return (Int(startMs), Int(endMs))
            }
        }
        try #require(segments.count == 1)
        #expect(segments[0].0 == 27000, "DB start_ms was \(segments[0].0)")
        #expect(segments[0].1 == 30000, "DB end_ms was \(segments[0].1)")
    }

    @Test func absoluteTimestampsPathTrustsTokenValues() async throws {
        // Companion gate: when providesAbsoluteTimestamps == true (the
        // default; Deepgram in Phase 6), TranscriptStore trusts
        // token.startMs / endMs directly without consulting the clock.
        let database = try Self.tempDB()
        let meetingID = ULID.generate()
        try await Self.insertMeetingRow(database, id: meetingID)

        let store = TranscriptStore(
            database: database,
            clock: {
                Issue.record("clock should not be called when providesAbsoluteTimestamps == true")
                return Date()
            }
        )
        store.beginMeeting(meetingID: meetingID, startedAt: Date(), displayName: "Anand")

        let token = TranscriptToken(
            startMs: 5000,
            endMs: 8000,
            speakerID: 0,
            text: "absolute path",
            confidence: nil,
            language: nil
        )
        await store.ingest(.final(token), source: .mic, providesAbsoluteTimestamps: true)

        let line = try #require(store.lines.first)
        #expect(line.timestamp == 5.0)
    }

    @Test func wallClockClampToZeroForUtteranceFinalizingBeforeDurationElapsed() async throws {
        // The intentional clamp documented in TranscriptStore.applyFinal:
        // when a final arrives less than `duration_ms` after meeting
        // start (rare — happens only if Sarvam emits mid-first-utterance
        // before its own VAD signals end-of-speech), the wall-clock
        // computed start would go negative. We clamp at zero rather
        // than report a bogus negative start_ms.
        let database = try Self.tempDB()
        let meetingID = ULID.generate()
        try await Self.insertMeetingRow(database, id: meetingID)

        let startedAt = Date(timeIntervalSince1970: 1_000_000)
        // Only 2 s elapsed, but Sarvam claims a 5 s segment duration.
        let fixedNow = startedAt.addingTimeInterval(2)
        let store = TranscriptStore(database: database, clock: { fixedNow })
        store.beginMeeting(meetingID: meetingID, startedAt: startedAt, displayName: "Anand")

        let token = TranscriptToken(
            startMs: 0,
            endMs: 5000, // claims 5 s, but only 2 s elapsed
            speakerID: 0,
            text: "early final",
            confidence: nil,
            language: nil
        )
        await store.ingest(.final(token), source: .mic, providesAbsoluteTimestamps: false)

        let line = try #require(store.lines.first)
        #expect(line.timestamp == 0.0, "expected clamp to 0; got \(line.timestamp)")
    }
}
