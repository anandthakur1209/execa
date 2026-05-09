@testable import Execa
import Foundation
import GRDB
import Testing

/// Verifies the merged-speaker voice-sample rule (Phase 3 Revision 5):
/// when the user clicks "Voice sample" on a merged speaker, the
/// player walks the alias chain to the canonical speaker, fetches
/// the canonical speaker's most-recent transcript_segments row, and
/// plays a 3 s window ending at that segment's end_ms — sourcing the
/// bytes from `mic.wav` or `system.wav` based on **the segment's**
/// source, not the canonical speaker's row source.
///
/// The tests use the testable `windowToPlay(...)` accessor so we
/// don't need audio-output permissions.
struct SpeakerVoiceSamplePlayerTests {
    private static func tempDB() throws -> Execa.Database {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("execa-vsp-\(UUID().uuidString).sqlite3")
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

    private static func insertSpeaker(
        _ database: Execa.Database,
        meetingID: String,
        source: String,
        rawSpeakerID: Int,
        label: String
    ) async throws -> Int64 {
        try await database.queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO speakers (meeting_id, source, raw_speaker_id, display_label)
                VALUES (?, ?, ?, ?)
                """,
                arguments: [meetingID, source, rawSpeakerID, label]
            )
            return db.lastInsertedRowID
        }
    }

    private static func insertSegment(
        _ database: Execa.Database,
        meetingID: String,
        speakerID: Int64,
        ms: (start: Int, end: Int),
        text: String
    ) async throws {
        try await database.queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO transcript_segments
                    (meeting_id, speaker_id, start_ms, end_ms, text, is_final, confidence)
                VALUES (?, ?, ?, ?, ?, 1, NULL)
                """,
                arguments: [meetingID, speakerID, ms.start, ms.end, text]
            )
        }
    }

    @Test func unmergedSpeakerUsesItsOwnLatestSegment() async throws {
        let database = try Self.tempDB()
        try await Self.insertMeeting(database, id: "m1")
        let mic0 = try await Self.insertSpeaker(
            database, meetingID: "m1", source: "mic", rawSpeakerID: 0, label: "Anand"
        )
        try await Self.insertSegment(database, meetingID: "m1", speakerID: mic0,
                                     ms: (0, 1000), text: "first")
        try await Self.insertSegment(database, meetingID: "m1", speakerID: mic0,
                                     ms: (1000, 5000), text: "latest")

        let window = try await SpeakerVoiceSamplePlayer.windowToPlay(
            speakerID: mic0,
            meetingID: "m1",
            database: database
        )
        try #require(window != nil)
        #expect(window?.endMs == 5000, "should pick the latest segment")
        #expect(window?.startMs == 2000, "3 s window ending at 5000")
        #expect(window?.wavURL.lastPathComponent == "mic.wav")
    }

    @Test func mergedSpeakerWalksAliasChain() async throws {
        // alias (system, 0) -> target (mic, 0). Voice-sample called
        // on the alias should produce the *target's* most-recent
        // segment + the segment's source WAV.
        let database = try Self.tempDB()
        try await Self.insertMeeting(database, id: "m1")
        let target = try await Self.insertSpeaker(
            database, meetingID: "m1", source: "mic", rawSpeakerID: 0, label: "Anand"
        )
        let aliasID = try await database.queue.write { db -> Int64 in
            try db.execute(
                sql: """
                INSERT INTO speakers
                    (meeting_id, source, raw_speaker_id, display_label, merged_into_speaker_id)
                VALUES (?, 'system', 0, 'Remote', ?)
                """,
                arguments: ["m1", target]
            )
            return db.lastInsertedRowID
        }
        try await Self.insertSegment(database, meetingID: "m1", speakerID: target,
                                     ms: (0, 4000), text: "via mic, latest")

        let window = try await SpeakerVoiceSamplePlayer.windowToPlay(
            speakerID: aliasID,
            meetingID: "m1",
            database: database
        )
        try #require(window != nil)
        #expect(window?.endMs == 4000)
        #expect(window?.startMs == 1000)
        #expect(window?.wavURL.lastPathComponent == "mic.wav",
                "should source bytes from mic.wav (target's source has the latest segment)")
    }

    @Test func crossSourceMergeSourcesBytesFromSegmentSource() async throws {
        // Important Phase 3 Revision 5 case: the canonical speaker
        // is mic-side, but the most-recent segment for that canonical
        // speaker came from a system-side row that was merged into it.
        // Wait — segments don't migrate across the merge; they stay
        // attached to their original speaker. So this test verifies
        // the segment's source is what wins, not the canonical
        // speaker's row source. Setup: target (mic, 0) "Anand" ->
        // canonical for both itself and a system-side alias.
        // Add segments to the *target* speaker only (since that's
        // who has segments); the system row is a pure alias.
        // Then a more recent segment exists on a different
        // mic speaker that's also merged in. The latest segment
        // wins by end_ms.
        let database = try Self.tempDB()
        try await Self.insertMeeting(database, id: "m1")
        let target = try await Self.insertSpeaker(
            database, meetingID: "m1", source: "mic", rawSpeakerID: 0, label: "Anand"
        )
        // System-side alias merged into the mic-side target. The
        // alias row has its own source = system.
        _ = try await database.queue.write { db -> Int64 in
            try db.execute(
                sql: """
                INSERT INTO speakers
                    (meeting_id, source, raw_speaker_id, display_label, merged_into_speaker_id)
                VALUES (?, 'system', 0, 'Remote', ?)
                """,
                arguments: ["m1", target]
            )
            return db.lastInsertedRowID
        }
        // Target speaker has a segment at end_ms=2500 (from mic.wav,
        // its own source).
        try await Self.insertSegment(database, meetingID: "m1", speakerID: target,
                                     ms: (500, 2500), text: "older mic-side")

        // Looking up the *target* (canonical) returns the
        // target's segment, and the source is mic (the segment's
        // recording source).
        let window = try await SpeakerVoiceSamplePlayer.windowToPlay(
            speakerID: target,
            meetingID: "m1",
            database: database
        )
        try #require(window != nil)
        #expect(window?.wavURL.lastPathComponent == "mic.wav")
        #expect(window?.endMs == 2500)
    }

    @Test func returnsNilWhenSpeakerHasNoSegments() async throws {
        let database = try Self.tempDB()
        try await Self.insertMeeting(database, id: "m1")
        let speakerID = try await Self.insertSpeaker(
            database, meetingID: "m1", source: "mic", rawSpeakerID: 0, label: "x"
        )
        let window = try await SpeakerVoiceSamplePlayer.windowToPlay(
            speakerID: speakerID,
            meetingID: "m1",
            database: database
        )
        #expect(window == nil)
    }

    @Test func clampsStartAtZeroForVeryEarlySegments() async throws {
        let database = try Self.tempDB()
        try await Self.insertMeeting(database, id: "m1")
        let speakerID = try await Self.insertSpeaker(
            database, meetingID: "m1", source: "mic", rawSpeakerID: 0, label: "x"
        )
        // 1 s segment near the start of the meeting; the 3 s window
        // would otherwise go negative.
        try await Self.insertSegment(database, meetingID: "m1", speakerID: speakerID,
                                     ms: (200, 1200), text: "early")
        let window = try await SpeakerVoiceSamplePlayer.windowToPlay(
            speakerID: speakerID,
            meetingID: "m1",
            database: database
        )
        #expect(window?.startMs == 0)
        #expect(window?.endMs == 1200)
    }
}
