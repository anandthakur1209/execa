@testable import Execa
import Foundation
import GRDB
import Testing

/// BUG 7 regression coverage: `TranscriptLine.speakerLabel` was
/// captured-by-value at line creation, so renaming a speaker
/// updated the DB but past transcript turns kept the stale label
/// until the next `.final` event arrived. The fix added
/// `applyRename`/`applyMerge`/`applySplit` propagation methods on
/// `TranscriptStore` that walk `lines` and update labels in place,
/// triggering `@Observable` invalidation so SwiftUI re-renders.
///
/// Each test seeds the store via `ingest(.final ...)` (the same path
/// production uses), then calls the propagation method and asserts
/// every affected line carries the new label.
@MainActor
struct TranscriptStoreLabelPropagationTests {
    private static func tempDB() throws -> Execa.Database {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("execa-prop-\(UUID().uuidString).sqlite3")
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

    private static func makeStore(displayName: String?) async throws -> (Execa.Database, TranscriptStore) {
        let database = try Self.tempDB()
        try await Self.insertMeeting(database, id: "m1")
        let store = TranscriptStore(database: database)
        store.beginMeeting(meetingID: "m1", startedAt: Date(), displayName: displayName)
        return (database, store)
    }

    private static func finalEvent(rawSpeakerID: Int, startMs: Int, endMs: Int, text: String) -> TranscriptionEvent {
        .final(TranscriptToken(
            startMs: startMs,
            endMs: endMs,
            speakerID: rawSpeakerID,
            text: text,
            confidence: nil,
            language: "en-IN"
        ))
    }

    @Test func applyRenameUpdatesAllLinesForThatSpeaker() async throws {
        let (_, store) = try await Self.makeStore(displayName: "Anand Thakur")
        // Three finals from (mic, 0) -> labelled "Anand Thakur" by default.
        await store.ingest(Self.finalEvent(rawSpeakerID: 0, startMs: 0, endMs: 1000, text: "a"), source: .mic)
        await store.ingest(Self.finalEvent(rawSpeakerID: 0, startMs: 1000, endMs: 2000, text: "b"), source: .mic)
        await store.ingest(Self.finalEvent(rawSpeakerID: 0, startMs: 2000, endMs: 3000, text: "c"), source: .mic)

        try #require(store.lines.count == 3)
        for line in store.lines {
            #expect(line.speakerLabel == "Anand Thakur", "pre-rename label captured at line creation")
        }

        // The speakers row ID for (mic, 0) — the same one each line points at.
        let speakerID = try #require(store.lines[0].databaseSpeakerID)
        store.applyRename(speakerID: speakerID, newLabel: "Test Anand")

        for line in store.lines {
            #expect(line.speakerLabel == "Test Anand", "all 3 past lines should reflect the rename")
        }
    }

    @Test func applyRenameLeavesOtherSpeakersUntouched() async throws {
        let (_, store) = try await Self.makeStore(displayName: nil)
        await store.ingest(Self.finalEvent(rawSpeakerID: 0, startMs: 0, endMs: 1000, text: "a"), source: .mic)
        await store.ingest(Self.finalEvent(rawSpeakerID: 0, startMs: 0, endMs: 1000, text: "b"), source: .system)
        try #require(store.lines.count == 2)

        let micSpeakerID = try #require(store.lines.first { $0.source == .mic }?.databaseSpeakerID)
        store.applyRename(speakerID: micSpeakerID, newLabel: "Renamed")

        let micLine = try #require(store.lines.first { $0.source == .mic })
        let systemLine = try #require(store.lines.first { $0.source == .system })
        #expect(micLine.speakerLabel == "Renamed")
        #expect(systemLine.speakerLabel == "Remote", "system stream's label should not be touched")
    }

    @Test func applyMergeSubstitutesTargetLabel() async throws {
        let (_, store) = try await Self.makeStore(displayName: nil)
        await store.ingest(Self.finalEvent(rawSpeakerID: 0, startMs: 0, endMs: 1000, text: "a"), source: .mic)
        await store.ingest(Self.finalEvent(rawSpeakerID: 1, startMs: 1000, endMs: 2000, text: "b"), source: .mic)
        try #require(store.lines.count == 2)
        let aliasSpeakerID = try #require(store.lines.last?.databaseSpeakerID)

        // Merge "In-room 2" into "You" — the alias's lines should
        // now render with the target's label.
        store.applyMerge(sourceSpeakerID: aliasSpeakerID, targetLabel: "You")
        let aliasLine = try #require(store.lines.last)
        #expect(aliasLine.speakerLabel == "You", "alias line should display target's label after merge")
    }

    @Test func applySplitRetargetsAndRelabelsTheSegment() async throws {
        let (_, store) = try await Self.makeStore(displayName: "Anand")
        await store.ingest(Self.finalEvent(rawSpeakerID: 0, startMs: 0, endMs: 1000, text: "first"), source: .mic)
        await store.ingest(Self.finalEvent(rawSpeakerID: 0, startMs: 1000, endMs: 2000, text: "second"), source: .mic)
        try #require(store.lines.count == 2)
        let segmentID = try #require(store.lines[1].databaseSegmentID)

        store.applySplit(segmentID: segmentID, newSpeakerID: 999, newLabel: "Dev")

        let firstLine = store.lines[0]
        let secondLine = store.lines[1]
        // First line untouched; second line retargeted + relabelled.
        #expect(firstLine.speakerLabel == "Anand")
        #expect(secondLine.speakerLabel == "Dev")
        #expect(secondLine.databaseSpeakerID == 999)
    }

    @Test func applyRenameOnUnknownSpeakerIsNoOp() async throws {
        let (_, store) = try await Self.makeStore(displayName: "Anand")
        await store.ingest(Self.finalEvent(rawSpeakerID: 0, startMs: 0, endMs: 1000, text: "x"), source: .mic)
        try #require(store.lines.count == 1)

        store.applyRename(speakerID: 99999, newLabel: "Nope")
        // No line points at 99999, so the existing line stays as-is.
        #expect(store.lines[0].speakerLabel == "Anand")
    }
}
