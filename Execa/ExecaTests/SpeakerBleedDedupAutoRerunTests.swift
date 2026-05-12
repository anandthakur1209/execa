@testable import Execa
import Foundation
import GRDB
import Testing

// Phase 3.5c commit (b) — Part 1 of the auto-rerun tests.
//
// Verifies the `AppCoordinator` wiring contract: merge + split fire
// the auto-rerun hook; rename does not. Each test seeds DB state
// where a rerun's effect is observable (FK flip or stable wrong-FK
// survival), then drives the change through `AppCoordinator`.
//
// Companion file: `SpeakerBleedDedupRerunGuardTests` covers the
// `auto_speaker_bleed_dedup` early-return guard and the reset-first
// contract on the algorithm side. The helpers below are `internal`
// (no access modifier) so both files share one fixture surface.

/// Shared DB fixtures + utilities. Internal so the companion
/// guard-tests file can use the same helpers without duplication.
enum RerunTestHelpers {
    static func tempDB() throws -> Execa.Database {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("execa-rerun-topology-\(UUID().uuidString).sqlite3")
        return try Execa.Database.make(at: url)
    }

    static func insertMeeting(_ database: Execa.Database, id: String) async throws {
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

    static func insertSpeaker(
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

    static func insertSegment(
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

    static func dedupAuditFK(
        _ database: Execa.Database,
        segmentID: Int64
    ) async throws -> Int64? {
        try await database.queue.read { db in
            try Row.fetchOne(
                db,
                sql: """
                SELECT deduped_against_segment_id AS fk
                FROM transcript_segments WHERE id = ?
                """,
                arguments: [segmentID]
            )?["fk"] as Int64?
        }
    }

    static func setDedupAuditFK(
        _ database: Execa.Database,
        segmentID: Int64,
        targetID: Int64?
    ) async throws {
        try await database.queue.write { db in
            try db.execute(
                sql: """
                UPDATE transcript_segments
                SET deduped_against_segment_id = ?
                WHERE id = ?
                """,
                arguments: [targetID, segmentID]
            )
        }
    }

    /// Standalone `DiarizationService` bound to the test DB so tests
    /// can pre-seed dedup state via `rerunDedupForMeeting` without
    /// going through `AppCoordinator`. The `diarize` closure is
    /// unused by the rerun path — throwing stub is enough.
    @MainActor
    static func makeStandaloneService(
        database: Execa.Database
    ) async -> DiarizationService {
        let settings = SettingsStore(database: database)
        let statusStore = DiarizationStatusStore()
        return DiarizationService(
            database: database,
            statusStore: statusStore,
            settings: settings,
            diarize: { @Sendable _, _ in
                throw NSError(domain: "test-rerun", code: 0)
            }
        )
    }
}

@MainActor
struct SpeakerBleedDedupAutoRerunTests {
    @Test func autoRerunDedupOnMerge() async throws {
        // Case A from Phase 3.5c plan: Sarvam over-segments the system
        // side into two adjacent speakers. Mic captures a bleed of the
        // full utterance. Each system speaker alone contains only half
        // the mic's tokens (containment 0.5 < 0.75) → initial dedup
        // does not flag the mic. After the user merges the two system
        // speakers, the merge-aware re-derivation scores the mic
        // against the COMBINED text and flags it.
        let database = try RerunTestHelpers.tempDB()
        try await RerunTestHelpers.insertMeeting(database, id: "m1")

        let micSpeaker = try await RerunTestHelpers.insertSpeaker(
            database, meetingID: "m1", source: "mic", rawSpeakerID: 0, label: "Anand"
        )
        let micSegment = try await RerunTestHelpers.insertSegment(
            database, meetingID: "m1", speakerID: micSpeaker, ms: (0, 5000),
            text: "alpha beta gamma delta epsilon zeta"
        )
        let sys1 = try await RerunTestHelpers.insertSpeaker(
            database, meetingID: "m1", source: "system", rawSpeakerID: 0, label: "S1"
        )
        let sys2 = try await RerunTestHelpers.insertSpeaker(
            database, meetingID: "m1", source: "system", rawSpeakerID: 1, label: "S2"
        )
        _ = try await RerunTestHelpers.insertSegment(
            database, meetingID: "m1", speakerID: sys1, ms: (0, 2500),
            text: "alpha beta gamma"
        )
        _ = try await RerunTestHelpers.insertSegment(
            database, meetingID: "m1", speakerID: sys2, ms: (2500, 5000),
            text: "delta epsilon zeta"
        )

        // Initial dedup: case A → mic NOT flagged.
        let standalone = await RerunTestHelpers.makeStandaloneService(database: database)
        await standalone.rerunDedupForMeeting(meetingID: "m1")
        let preMergeFK = try await RerunTestHelpers.dedupAuditFK(database, segmentID: micSegment)
        try #require(preMergeFK == nil,
                     "case A pre-merge: mic should NOT flag against an over-segmented system")

        // Merge sys2 into sys1 via AppCoordinator — the rerun hook
        // fires as the final step of `mergeSpeakers`.
        let coordinator = try await AppCoordinator(database: database)
        try await coordinator.mergeSpeakers(sourceSpeakerID: sys2, intoTargetSpeakerID: sys1)

        let postMergeFK = try await RerunTestHelpers.dedupAuditFK(database, segmentID: micSegment)
        #expect(postMergeFK != nil,
                "after merge: rerun fires + merge-aware re-derivation flags mic")
    }

    @Test func autoRerunDedupOnSplit() async throws {
        // Cross-validation promoted a mic segment whose content didn't
        // match pairwise but whose owning speaker was ≥ 80% flagged.
        // The user splits that segment off into a new speaker. Under
        // the new (singleton) speaker, cross-validation no longer
        // satisfies the ≥ 3 minimum, so the segment loses its FK on
        // the re-run.
        let database = try RerunTestHelpers.tempDB()
        try await RerunTestHelpers.insertMeeting(database, id: "m1")

        let micSpeaker = try await RerunTestHelpers.insertSpeaker(
            database, meetingID: "m1", source: "mic", rawSpeakerID: 0, label: "Anand"
        )
        let sharedTokens = (1 ... 10).map { "tok\($0)" }.joined(separator: " ")
        var matchingMicSegments: [Int64] = []
        for idx in 0 ..< 4 {
            let id = try await RerunTestHelpers.insertSegment(
                database, meetingID: "m1", speakerID: micSpeaker,
                ms: (idx * 2000, idx * 2000 + 1500), text: sharedTokens
            )
            matchingMicSegments.append(id)
        }
        let promotedMicSegment = try await RerunTestHelpers.insertSegment(
            database, meetingID: "m1", speakerID: micSpeaker,
            ms: (20000, 21000), text: "unrelated promoted content"
        )

        // System speaker covers only the four matching windows
        // (0–7500). The gap leaves segment 5 with no overlapping
        // system segment, so pairwise can't flag it — only cross-val
        // promotion catches it. That's the behavior split reverses.
        let systemSpeaker = try await RerunTestHelpers.insertSpeaker(
            database, meetingID: "m1", source: "system", rawSpeakerID: 0, label: "Remote"
        )
        for idx in 0 ..< 4 {
            _ = try await RerunTestHelpers.insertSegment(
                database, meetingID: "m1", speakerID: systemSpeaker,
                ms: (idx * 2000, idx * 2000 + 1500), text: sharedTokens
            )
        }

        let standalone = await RerunTestHelpers.makeStandaloneService(database: database)
        await standalone.rerunDedupForMeeting(meetingID: "m1")
        let preSplitFK = try await RerunTestHelpers.dedupAuditFK(
            database, segmentID: promotedMicSegment
        )
        try #require(preSplitFK != nil,
                     "pre-split: cross-val promotes segment 5 of 5 flagged speaker")

        // User splits the promoted segment into its own speaker. The
        // rerun hook fires as the final step of `splitSegment`.
        let coordinator = try await AppCoordinator(database: database)
        _ = try await coordinator.splitSegment(
            segmentID: promotedMicSegment, intoNewLabel: "Different"
        )

        // The split-off segment now lives under a 1-segment speaker;
        // cross-val no longer satisfies `minFlagged = 3`. The
        // reset-first re-run clears its FK and doesn't re-set it.
        let postSplitFK = try await RerunTestHelpers.dedupAuditFK(
            database, segmentID: promotedMicSegment
        )
        #expect(postSplitFK == nil,
                "after split: promoted segment loses its FK (cross-val no longer fires for it)")
        // Pairwise-flagged segments stay flagged — their content
        // match is independent of the speaker topology.
        for matchingID in matchingMicSegments {
            let fk = try await RerunTestHelpers.dedupAuditFK(database, segmentID: matchingID)
            #expect(fk != nil,
                    "pairwise-flagged segment \(matchingID) should remain flagged after split")
        }
    }

    @Test func renameDoesNotRerunDedup() async throws {
        // Rename is a label-only change; the topology (speaker_id +
        // merged_into_speaker_id chain) is unchanged, so no re-run
        // hook fires. We prove this by seeding a deliberately-WRONG
        // audit FK: if the rerun fired (and was reset-first), the FK
        // would be re-derived to point at the true text match. The
        // assertion that the wrong FK survives the rename proves the
        // hook didn't fire.
        let database = try RerunTestHelpers.tempDB()
        try await RerunTestHelpers.insertMeeting(database, id: "m1")

        let micSpeaker = try await RerunTestHelpers.insertSpeaker(
            database, meetingID: "m1", source: "mic", rawSpeakerID: 0, label: "Anand"
        )
        let micSegment = try await RerunTestHelpers.insertSegment(
            database, meetingID: "m1", speakerID: micSpeaker, ms: (0, 2000),
            text: "alpha beta gamma delta epsilon"
        )
        let matchingSystem = try await RerunTestHelpers.insertSpeaker(
            database, meetingID: "m1", source: "system", rawSpeakerID: 0, label: "S-match"
        )
        let unrelatedSystem = try await RerunTestHelpers.insertSpeaker(
            database, meetingID: "m1", source: "system", rawSpeakerID: 1, label: "S-unrelated"
        )
        let matchingSegment = try await RerunTestHelpers.insertSegment(
            database, meetingID: "m1", speakerID: matchingSystem, ms: (0, 2000),
            text: "alpha beta gamma delta epsilon"
        )
        let unrelatedSegment = try await RerunTestHelpers.insertSegment(
            database, meetingID: "m1", speakerID: unrelatedSystem, ms: (10000, 12000),
            text: "totally different content here"
        )

        // Manually seed a WRONG audit FK on the mic segment, pointing
        // at the unrelated system segment. If rerun fired, it would
        // re-derive to point at the matching segment.
        try await RerunTestHelpers.setDedupAuditFK(
            database, segmentID: micSegment, targetID: unrelatedSegment
        )
        let preRenameFK = try await RerunTestHelpers.dedupAuditFK(
            database, segmentID: micSegment
        )
        try #require(preRenameFK == unrelatedSegment, "test setup invariant")

        // Rename via AppCoordinator. The rename hook does NOT call
        // `rerunDedupForMeeting`.
        let coordinator = try await AppCoordinator(database: database)
        try await coordinator.renameSpeaker(speakerID: micSpeaker, to: "Renamed")

        let postRenameFK = try await RerunTestHelpers.dedupAuditFK(
            database, segmentID: micSegment
        )
        #expect(postRenameFK == unrelatedSegment,
                "rename must not trigger rerun: wrong FK survives unchanged")
        // Sanity: the algorithm would have picked the matching
        // segment. Make that explicit so future readers don't wonder.
        #expect(matchingSegment != unrelatedSegment, "fixture sanity")
    }
}
