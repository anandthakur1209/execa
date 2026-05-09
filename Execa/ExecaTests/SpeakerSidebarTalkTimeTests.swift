@testable import Execa
import Foundation
import GRDB
import Testing

/// View-model unit tests for the live talk-time tally on
/// `TranscriptStore`. Drives the store with synthetic `.final` events
/// (the same shape `SarvamProvider` emits), reads
/// `talkTimeBySpeaker`, asserts that durations sum correctly per
/// speakers.id.
///
/// The SwiftUI surface (`SpeakerSidebar`) reads this map directly;
/// the join step is in `SpeakerSidebar.derive(...)` and is exercised
/// in the integration smoke (manual). Tests here focus on the data
/// path so the per-final accumulator stays correct under edits.
@MainActor
struct SpeakerSidebarTalkTimeTests {
    private static func tempDB() throws -> Execa.Database {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("execa-tt-\(UUID().uuidString).sqlite3")
        return try Execa.Database.make(at: url)
    }

    private static func insertMeeting(_ database: Execa.Database, id: String) async throws {
        try await database.queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO meetings (id, title, started_at, status)
                VALUES (?, NULL, ?, 'recording')
                """,
                arguments: [id, Int64(Date().timeIntervalSince1970 * 1000)]
            )
        }
    }

    /// Produces a `.final` TranscriptionEvent for the given source +
    /// raw_speaker_id with `(startMs, endMs)` carrying absolute
    /// timestamps (matches what the streaming provider emits when
    /// `providesAbsoluteTimestamps == true`).
    private static func finalEvent(
        text: String,
        rawSpeakerID: Int,
        startMs: Int,
        endMs: Int
    ) -> TranscriptionEvent {
        .final(TranscriptToken(
            startMs: startMs,
            endMs: endMs,
            speakerID: rawSpeakerID,
            text: text,
            confidence: nil,
            language: "en-IN"
        ))
    }

    @Test func singleSpeakerSumsDurations() async throws {
        let database = try Self.tempDB()
        try await Self.insertMeeting(database, id: "m1")
        let store = TranscriptStore(database: database)
        store.beginMeeting(meetingID: "m1", startedAt: Date(), displayName: "Anand")

        // 1.5 s + 2.0 s = 3.5 s for the same mic-0 speaker.
        await store.ingest(Self.finalEvent(text: "first", rawSpeakerID: 0, startMs: 0, endMs: 1500), source: .mic)
        await store.ingest(Self.finalEvent(text: "second", rawSpeakerID: 0, startMs: 1500, endMs: 3500), source: .mic)

        // Only one speaker should be in the map.
        try #require(store.talkTimeBySpeaker.count == 1)
        let total = store.talkTimeBySpeaker.values.first ?? -1
        #expect(total == 3.5, "talk-time should be 3.5 s, got \(total)")
    }

    @Test func twoSourcesGetIndependentTallies() async throws {
        let database = try Self.tempDB()
        try await Self.insertMeeting(database, id: "m1")
        let store = TranscriptStore(database: database)
        store.beginMeeting(meetingID: "m1", startedAt: Date(), displayName: nil)

        await store.ingest(Self.finalEvent(text: "u", rawSpeakerID: 0, startMs: 0, endMs: 1000), source: .mic)
        await store.ingest(Self.finalEvent(text: "r", rawSpeakerID: 0, startMs: 0, endMs: 2500), source: .system)
        await store.ingest(Self.finalEvent(text: "u-2", rawSpeakerID: 0, startMs: 1000, endMs: 1500), source: .mic)

        #expect(store.talkTimeBySpeaker.count == 2, "mic and system create distinct speakers.id")
        #expect(store.talkTimeBySpeaker.values.contains(1.5))
        #expect(store.talkTimeBySpeaker.values.contains(2.5))
    }

    @Test func multipleSpeakersWithinOneSourceSumIndependently() async throws {
        let database = try Self.tempDB()
        try await Self.insertMeeting(database, id: "m1")
        let store = TranscriptStore(database: database)
        store.beginMeeting(meetingID: "m1", startedAt: Date(), displayName: nil)

        await store.ingest(Self.finalEvent(text: "a", rawSpeakerID: 0, startMs: 0, endMs: 1000), source: .system)
        await store.ingest(Self.finalEvent(text: "b", rawSpeakerID: 1, startMs: 1000, endMs: 3000), source: .system)
        await store.ingest(Self.finalEvent(text: "c", rawSpeakerID: 0, startMs: 3000, endMs: 3500), source: .system)

        // Two distinct (system, raw_speaker_id) pairs; one with 1.5 s, one with 2 s.
        try #require(store.talkTimeBySpeaker.count == 2)
        let totals = Set(store.talkTimeBySpeaker.values)
        #expect(totals == [1.5, 2.0])
    }

    @Test func resetsOnBeginMeeting() async throws {
        let database = try Self.tempDB()
        try await Self.insertMeeting(database, id: "m1")
        let store = TranscriptStore(database: database)
        store.beginMeeting(meetingID: "m1", startedAt: Date(), displayName: nil)
        await store.ingest(Self.finalEvent(text: "x", rawSpeakerID: 0, startMs: 0, endMs: 1000), source: .mic)
        try #require(!store.talkTimeBySpeaker.isEmpty)

        try await Self.insertMeeting(database, id: "m2")
        store.beginMeeting(meetingID: "m2", startedAt: Date(), displayName: nil)
        #expect(store.talkTimeBySpeaker.isEmpty, "begin should wipe the per-meeting tally")
    }
}
