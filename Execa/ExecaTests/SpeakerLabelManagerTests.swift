@testable import Execa
import Foundation
import GRDB
import Testing

/// DB-driven tests for `SpeakerLabelManager`. Phase 3 commit 1 covered
/// `rename`; commit 5 adds merge (same-source + cross-source +
/// idempotent re-merge) and split coverage. The merge-alias-resolving
/// `SpeakerQueries` helpers (`canonicalSpeakerID`, `effectiveLabel`,
/// `talkTimeAggregated`) are also exercised here.
struct SpeakerLabelManagerTests {
    private static func tempDB() throws -> Execa.Database {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("execa-slm-\(UUID().uuidString).sqlite3")
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
    ) async throws -> Int64 {
        try await database.queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO transcript_segments
                    (meeting_id, speaker_id, start_ms, end_ms, text, is_final, confidence)
                VALUES (?, ?, ?, ?, ?, 1, NULL)
                """,
                arguments: [meetingID, speakerID, ms.start, ms.end, text]
            )
            return db.lastInsertedRowID
        }
    }

    // MARK: - Rename (commit 1 coverage, kept here)

    @Test func renameUpdatesDisplayLabel() async throws {
        let database = try Self.tempDB()
        try await Self.insertMeeting(database, id: "m1")
        let speakerID = try await Self.insertSpeaker(
            database, meetingID: "m1", source: "mic", rawSpeakerID: 0, label: "You"
        )
        let manager = SpeakerLabelManager(database: database)
        try await manager.rename(speakerID: speakerID, to: "Anand")
        let label = try await database.queue.read { db in
            try SpeakerQueries.displayLabel(speakerID: speakerID, in: db)
        }
        #expect(label == "Anand")
    }

    @Test func renameTrimsWhitespace() async throws {
        let database = try Self.tempDB()
        try await Self.insertMeeting(database, id: "m1")
        let speakerID = try await Self.insertSpeaker(
            database, meetingID: "m1", source: "mic", rawSpeakerID: 0, label: "You"
        )
        let manager = SpeakerLabelManager(database: database)
        try await manager.rename(speakerID: speakerID, to: "  Maya  \n")
        let label = try await database.queue.read { db in
            try SpeakerQueries.displayLabel(speakerID: speakerID, in: db)
        }
        #expect(label == "Maya")
    }

    @Test func renameRejectsEmptyLabel() async throws {
        let database = try Self.tempDB()
        try await Self.insertMeeting(database, id: "m1")
        let speakerID = try await Self.insertSpeaker(
            database, meetingID: "m1", source: "mic", rawSpeakerID: 0, label: "You"
        )
        let manager = SpeakerLabelManager(database: database)
        await #expect(throws: SpeakerLabelManagerError.emptyLabel) {
            try await manager.rename(speakerID: speakerID, to: "   \t\n")
        }
        let label = try await database.queue.read { db in
            try SpeakerQueries.displayLabel(speakerID: speakerID, in: db)
        }
        #expect(label == "You")
    }
}

/// Merge + split + alias-resolution coverage. Split out from
/// `SpeakerLabelManagerTests` to keep both struct bodies under the
/// type-body-length cap.
struct SpeakerLabelManagerMergeSplitTests {
    private static func tempDB() throws -> Execa.Database {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("execa-slm-ms-\(UUID().uuidString).sqlite3")
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
    ) async throws -> Int64 {
        try await database.queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO transcript_segments
                    (meeting_id, speaker_id, start_ms, end_ms, text, is_final, confidence)
                VALUES (?, ?, ?, ?, ?, 1, NULL)
                """,
                arguments: [meetingID, speakerID, ms.start, ms.end, text]
            )
            return db.lastInsertedRowID
        }
    }

    // MARK: - Merge

    @Test func mergeSameSourceSetsAliasFK() async throws {
        let database = try Self.tempDB()
        try await Self.insertMeeting(database, id: "m1")
        let aliasID = try await Self.insertSpeaker(
            database, meetingID: "m1", source: "mic", rawSpeakerID: 1, label: "In-room 2"
        )
        let targetID = try await Self.insertSpeaker(
            database, meetingID: "m1", source: "mic", rawSpeakerID: 0, label: "Anand"
        )
        let manager = SpeakerLabelManager(database: database)
        try await manager.merge(sourceSpeakerID: aliasID, intoTargetSpeakerID: targetID)

        let canonical = try await database.queue.read { db in
            try SpeakerQueries.canonicalSpeakerID(aliasID, in: db)
        }
        #expect(canonical == targetID)
        let effective = try await database.queue.read { db in
            try SpeakerQueries.effectiveLabel(aliasID, in: db)
        }
        #expect(effective == "Anand")
    }

    @Test func mergeCrossSourceWorksAndAggregatesTalkTime() async throws {
        // Speaker bleed-through case: a remote person heard via
        // speakers shows up on both mic and system streams. User
        // collapses them with a cross-source merge.
        let database = try Self.tempDB()
        try await Self.insertMeeting(database, id: "m1")
        let micSpeaker = try await Self.insertSpeaker(
            database, meetingID: "m1", source: "mic", rawSpeakerID: 1, label: "In-room 2"
        )
        let systemSpeaker = try await Self.insertSpeaker(
            database, meetingID: "m1", source: "system", rawSpeakerID: 0, label: "Maya"
        )
        _ = try await Self.insertSegment(database, meetingID: "m1", speakerID: micSpeaker,
                                         ms: (0, 1500), text: "via mic")
        _ = try await Self.insertSegment(database, meetingID: "m1", speakerID: systemSpeaker,
                                         ms: (1500, 4500), text: "via system")

        let manager = SpeakerLabelManager(database: database)
        try await manager.merge(sourceSpeakerID: micSpeaker, intoTargetSpeakerID: systemSpeaker)

        let effective = try await database.queue.read { db in
            try SpeakerQueries.effectiveLabel(micSpeaker, in: db)
        }
        #expect(effective == "Maya", "alias should resolve to target's label")

        let talkTime = try await database.queue.read { db in
            try SpeakerQueries.talkTimeAggregated(meetingID: "m1", in: db)
        }
        #expect(talkTime[systemSpeaker] == 4500, "merged talk time should sum across both sources")
        #expect(talkTime[micSpeaker] == nil, "alias key shouldn't appear in the aggregated result")
    }

    @Test func mergeIntoSelfThrows() async throws {
        let database = try Self.tempDB()
        try await Self.insertMeeting(database, id: "m1")
        let speakerID = try await Self.insertSpeaker(
            database, meetingID: "m1", source: "mic", rawSpeakerID: 0, label: "You"
        )
        let manager = SpeakerLabelManager(database: database)
        await #expect(throws: SpeakerLabelManagerError.mergeIntoSelf) {
            try await manager.merge(sourceSpeakerID: speakerID, intoTargetSpeakerID: speakerID)
        }
    }

    @Test func mergeIsIdempotentOnRepeatCall() async throws {
        let database = try Self.tempDB()
        try await Self.insertMeeting(database, id: "m1")
        let aliasID = try await Self.insertSpeaker(
            database, meetingID: "m1", source: "mic", rawSpeakerID: 1, label: "B"
        )
        let targetID = try await Self.insertSpeaker(
            database, meetingID: "m1", source: "mic", rawSpeakerID: 0, label: "A"
        )
        let manager = SpeakerLabelManager(database: database)
        try await manager.merge(sourceSpeakerID: aliasID, intoTargetSpeakerID: targetID)
        // Second call: no error, and the alias FK is unchanged.
        try await manager.merge(sourceSpeakerID: aliasID, intoTargetSpeakerID: targetID)
        let postLink: Int64?? = try await database.queue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT merged_into_speaker_id FROM speakers WHERE id = ?",
                arguments: [aliasID]
            ).map { $0["merged_into_speaker_id"] as Int64? }
        }
        try #require(postLink != nil)
        #expect(postLink ?? nil == targetID)
    }

    // MARK: - Split (commit 5)

    @Test func splitInsertsNewSpeakerAndReassignsSegment() async throws {
        let database = try Self.tempDB()
        try await Self.insertMeeting(database, id: "m1")
        let original = try await Self.insertSpeaker(
            database, meetingID: "m1", source: "mic", rawSpeakerID: 0, label: "Anand"
        )
        let segment = try await Self.insertSegment(
            database, meetingID: "m1", speakerID: original,
            ms: (0, 1000), text: "actually a different speaker"
        )

        let manager = SpeakerLabelManager(database: database)
        let newID = try await manager.split(segmentID: segment, intoNewLabel: "Dev")

        // New speaker exists with the next raw_speaker_id.
        let newRow = try await database.queue.read { db in
            try Row.fetchOne(
                db,
                sql: """
                SELECT source, raw_speaker_id, display_label
                FROM speakers WHERE id = ?
                """,
                arguments: [newID]
            )
        }
        try #require(newRow != nil)
        #expect(newRow?["source"] as String? == "mic")
        #expect(newRow?["raw_speaker_id"] as Int? == 1, "should be max(existing) + 1")
        #expect(newRow?["display_label"] as String? == "Dev")

        // Segment's speaker_id reassigned.
        let reassigned: Int64? = try await database.queue.read { db in
            try Int64.fetchOne(
                db,
                sql: "SELECT speaker_id FROM transcript_segments WHERE id = ?",
                arguments: [segment]
            )
        }
        #expect(reassigned == newID)
    }

    @Test func splitLeavesOtherSegmentsAttributedToOriginal() async throws {
        let database = try Self.tempDB()
        try await Self.insertMeeting(database, id: "m1")
        let original = try await Self.insertSpeaker(
            database, meetingID: "m1", source: "mic", rawSpeakerID: 0, label: "Anand"
        )
        let segmentA = try await Self.insertSegment(database, meetingID: "m1",
                                                    speakerID: original,
                                                    ms: (0, 1000), text: "A")
        let segmentB = try await Self.insertSegment(database, meetingID: "m1",
                                                    speakerID: original,
                                                    ms: (1000, 2000), text: "B")

        let manager = SpeakerLabelManager(database: database)
        _ = try await manager.split(segmentID: segmentB, intoNewLabel: "Maya")

        let stillOriginal: Int64? = try await database.queue.read { db in
            try Int64.fetchOne(
                db,
                sql: "SELECT speaker_id FROM transcript_segments WHERE id = ?",
                arguments: [segmentA]
            )
        }
        #expect(stillOriginal == original, "the un-split segment should remain attributed to the original speaker")
    }

    @Test func splitRejectsEmptyLabel() async throws {
        let database = try Self.tempDB()
        try await Self.insertMeeting(database, id: "m1")
        let original = try await Self.insertSpeaker(
            database, meetingID: "m1", source: "mic", rawSpeakerID: 0, label: "Anand"
        )
        let segment = try await Self.insertSegment(database, meetingID: "m1",
                                                   speakerID: original,
                                                   ms: (0, 1000), text: "x")
        let manager = SpeakerLabelManager(database: database)
        await #expect(throws: SpeakerLabelManagerError.emptyLabel) {
            _ = try await manager.split(segmentID: segment, intoNewLabel: "  \t  ")
        }
    }

    @Test func splitOnMissingSegmentThrows() async throws {
        let database = try Self.tempDB()
        let manager = SpeakerLabelManager(database: database)
        await #expect(throws: SpeakerLabelManagerError.segmentNotFound) {
            _ = try await manager.split(segmentID: 9999, intoNewLabel: "Dev")
        }
    }

    @Test func talkTimeAggregatedHandlesUnmergedSpeakers() async throws {
        let database = try Self.tempDB()
        try await Self.insertMeeting(database, id: "m1")
        let aSpeaker = try await Self.insertSpeaker(
            database, meetingID: "m1", source: "mic", rawSpeakerID: 0, label: "A"
        )
        let bSpeaker = try await Self.insertSpeaker(
            database, meetingID: "m1", source: "mic", rawSpeakerID: 1, label: "B"
        )
        _ = try await Self.insertSegment(database, meetingID: "m1", speakerID: aSpeaker,
                                         ms: (0, 2000), text: "x")
        _ = try await Self.insertSegment(database, meetingID: "m1", speakerID: bSpeaker,
                                         ms: (2000, 3500), text: "y")
        let result = try await database.queue.read { db in
            try SpeakerQueries.talkTimeAggregated(meetingID: "m1", in: db)
        }
        #expect(result[aSpeaker] == 2000)
        #expect(result[bSpeaker] == 1500)
    }
}
