@testable import Execa
import Foundation
import GRDB
import Testing

/// Phase 3.5c commit (a) tests for the merge-aware v2 algorithm.
/// Pure-function tests for `pairsToDedupV2` driven through synthetic
/// `Segment` arrays where `effectiveSpeakerID` differs from
/// `speakerID` to simulate post-merge topology. One DB-driven test at
/// the end exercises `SpeakerBleedDeduper.dedup`'s reset-first
/// behaviour against pre-existing audit FKs.
struct SpeakerBleedDedupV2MergeAwareTests {
    private static func mic(
        id: Int64,
        speakerID: Int64,
        start: Int,
        end: Int,
        text: String,
        confidence: Double? = nil
    ) -> SpeakerBleedDeduper.Segment {
        .init(
            id: id,
            speakerID: speakerID,
            effectiveSpeakerID: speakerID,
            source: "mic",
            startMs: start,
            endMs: end,
            text: text,
            confidence: confidence
        )
    }

    /// System helper. `effectiveSpeakerID` defaults to `speakerID`
    /// (un-merged); pass a distinct value to simulate "this raw
    /// system speaker was merged into another."
    private static func sys(
        id: Int64,
        speakerID: Int64,
        effectiveSpeakerID: Int64? = nil,
        start: Int,
        end: Int,
        text: String,
        confidence: Double? = nil
    ) -> SpeakerBleedDeduper.Segment {
        .init(
            id: id,
            speakerID: speakerID,
            effectiveSpeakerID: effectiveSpeakerID ?? speakerID,
            source: "system",
            startMs: start,
            endMs: end,
            text: text,
            confidence: confidence
        )
    }

    // MARK: - Pairwise against combined effective-speaker text

    @Test func pairwiseRespectsEffectiveSpeakerCombinedText() throws {
        // Mic captures 30 tokens that fall in 3 distinct system
        // segments (raw speakers 200, 201, 202), each carrying ~10
        // of those tokens. Pre-merge: pairwise sees each system
        // segment individually; containment of mic vs any single
        // segment is ~0.33 (10/30), below 0.75. No flag.
        // Post-merge (all three raw speakers merged into 200): the
        // effective speaker's combined text covers all 30 mic
        // tokens. Containment 30/30 = 1.0 → flag. Audit FK anchors
        // on the best-overlap constituent segment.
        let micTokens = (1 ... 30).map { "tok\($0)" }.joined(separator: " ")
        let mics = [Self.mic(id: 1, speakerID: 100, start: 1000, end: 4000, text: micTokens)]
        // Three system segments, all merged into effective speaker
        // 200. Mic time window 1000–4000 overlaps system seg id 11
        // (1000–2000) most.
        let chunk1 = (1 ... 10).map { "tok\($0)" }.joined(separator: " ")
        let chunk2 = (11 ... 20).map { "tok\($0)" }.joined(separator: " ")
        let chunk3 = (21 ... 30).map { "tok\($0)" }.joined(separator: " ")
        let systems = [
            Self.sys(id: 10, speakerID: 200, start: 0, end: 500, text: chunk1),
            Self.sys(id: 11, speakerID: 201, effectiveSpeakerID: 200,
                     start: 1000, end: 2000, text: chunk2),
            Self.sys(id: 12, speakerID: 202, effectiveSpeakerID: 200,
                     start: 2500, end: 4000, text: chunk3)
        ]
        let pairs = SpeakerBleedDeduper.pairsToDedup(segments: mics + systems, version: .v2)
        try #require(pairs.count == 1)
        #expect(pairs.first?.dedupedID == 1)
        #expect(pairs.first?.containment == 1.0)
        #expect(pairs.first?.promotionReason == .pairwise)
        // Best-overlap anchor: system seg 11 (1000–2000 fully inside
        // mic 1000–4000) has overlap fraction 1.0. Seg 12 (2500–
        // 4000) overlap is 1500 / min(1500, 3000) = 1.0 too — tie.
        // Tie → longer duration: seg 12 (1500) > seg 11 (1000), so
        // seg 12 wins.
        #expect(pairs.first?.againstID == 12,
                "best-overlap anchor: longest segment among tied-overlap candidates")
    }

    // MARK: - Cross-validation by effective speaker

    @Test func crossValidationGroupsByEffectiveSpeaker() throws {
        // Mic has 5 segments, each matching one of 5 raw system
        // speakers — but all 5 raw systems are merged into a single
        // effective speaker. Pre-merge cross-validation would see
        // 5 different system speakers (count 1 each); post-merge
        // (effective grouping) sees count 5 against the single
        // effective speaker. Mic ratio 5/5 = 1.0 → all flagged
        // pairwise, no cross-validation needed; the test asserts
        // the audit FKs point at segments belonging to the effective
        // speaker's segments (not the un-merged raw speakers).
        let shared = (1 ... 10).map { "tok\($0)" }.joined(separator: " ")
        let mics = (1 ... 5).map { idx -> SpeakerBleedDeduper.Segment in
            Self.mic(
                id: Int64(idx), speakerID: 100,
                start: (idx - 1) * 2000, end: (idx - 1) * 2000 + 1500,
                text: shared
            )
        }
        // 5 raw system speakers, all merged into effective speaker 200.
        let systems = (1 ... 5).map { idx -> SpeakerBleedDeduper.Segment in
            Self.sys(
                id: Int64(100 + idx),
                speakerID: Int64(199 + idx), // 200, 201, 202, 203, 204
                effectiveSpeakerID: 200,
                start: (idx - 1) * 2000, end: (idx - 1) * 2000 + 1500,
                text: shared
            )
        }
        let pairs = SpeakerBleedDeduper.pairsToDedup(segments: mics + systems, version: .v2)
        try #require(pairs.count == 5, "all 5 mic segments should flag")
        for pair in pairs {
            // againstID points at one of the 5 raw segments (101–105);
            // those raw segments resolve to effective speaker 200.
            #expect((101 ... 105).contains(pair.againstID),
                    "audit FK points at a constituent segment of effective speaker 200")
            // PromotionReason can be either .pairwise (per-segment
            // text match) or .concatenation (same-speaker mic
            // streak whose joined text matches the effective
            // speaker's combined text). Both are valid v2 outcomes;
            // the test cares about post-merge consolidation, not
            // which pass fires.
            #expect([.pairwise, .concatenation].contains(pair.promotionReason))
        }
    }

    // MARK: - Concatenation pre-pass against combined effective text

    @Test func concatPrePassUsesEffectiveSpeakerCombinedText() throws {
        // Mic group of 3 same-speaker fragments inside the time
        // window of 3 merged-together system segments. Each
        // individual system segment doesn't contain the group's
        // joined text individually, but the combined effective-
        // speaker text does.
        let mics = [
            Self.mic(id: 1, speakerID: 100, start: 500, end: 1100,
                     text: "alpha beta gamma"),
            Self.mic(id: 2, speakerID: 100, start: 1500, end: 2100,
                     text: "delta epsilon zeta"),
            Self.mic(id: 3, speakerID: 100, start: 2500, end: 3100,
                     text: "eta theta iota")
        ]
        let systems = [
            Self.sys(id: 50, speakerID: 200, start: 0, end: 1200,
                     text: "alpha beta gamma kappa"),
            Self.sys(id: 51, speakerID: 201, effectiveSpeakerID: 200,
                     start: 1300, end: 2300, text: "delta epsilon zeta lambda"),
            Self.sys(id: 52, speakerID: 202, effectiveSpeakerID: 200,
                     start: 2400, end: 3500, text: "eta theta iota mu")
        ]
        let pairs = SpeakerBleedDeduper.pairsFromConcatenationPrePass(
            mics: mics,
            systems: systems
        )
        try #require(pairs.count == 3)
        for pair in pairs {
            #expect(pair.promotionReason == .concatenation)
            // All pairs target a constituent segment of effective
            // speaker 200 (one of ids 50/51/52).
            #expect([50, 51, 52].contains(pair.againstID))
        }
    }

    // MARK: - Paraphrase guard under merged topology

    @Test func paraphraseSurvivesUnderMergedSystemTopology() {
        // Mic-side user paraphrases content that's been merged
        // across 3 system speakers. The combined system text is
        // larger than any single segment, which could artificially
        // inflate |mic ∩ system|. Verify paraphrase guardrail still
        // holds: containment of paraphrase tokens vs combined
        // system text stays below 0.75. This is the merge-aware
        // version of the existing paraphraseStillNotFlaggedInV2
        // test in `SpeakerBleedDeduperTests`.
        let mics = [Self.mic(
            id: 1, speakerID: 100, start: 0, end: 4000,
            text: "you mean to say their numbers improved last quarter"
        )]
        let systems = [
            Self.sys(id: 50, speakerID: 200, start: 0, end: 1500,
                     text: "the quarterly figures"),
            Self.sys(id: 51, speakerID: 201, effectiveSpeakerID: 200,
                     start: 1500, end: 3000,
                     text: "showed strong growth"),
            Self.sys(id: 52, speakerID: 202, effectiveSpeakerID: 200,
                     start: 3000, end: 4500,
                     text: "across the board")
        ]
        // Combined effective-speaker text: "the quarterly figures
        // showed strong growth across the board". Stemmed tokens:
        // {the, quarterly, figur, showed, strong, growth, across,
        // the, board}. Mic stemmed tokens: {you, mean, to, say,
        // their, number, improv, last, quarter}. Intersection size
        // depends on stemmer — but in practice tokens diverge.
        // Containment of mic over system should stay below 0.75.
        let pairs = SpeakerBleedDeduper.pairsToDedup(segments: mics + systems, version: .v2)
        #expect(pairs.isEmpty,
                "paraphrase against merged-system combined text should still not flag; got \(pairs)")
    }

    // MARK: - Swap-time behaviour unchanged

    @Test func swapTimeBehaviorUnchangedWhenNoMerges() {
        // When every system segment has effectiveSpeakerID == speakerID
        // (the swap-time state with no merges yet), v2 produces the
        // same pairs as Phase 3.5b's swap-time tests would produce.
        // Regression guard against merge-aware accidentally changing
        // the swap-time path.
        let shared = "hello world from the remote speaker"
        let mics = [Self.mic(id: 1, speakerID: 100, start: 100, end: 1500, text: shared)]
        let systems = [Self.sys(id: 2, speakerID: 200, start: 0, end: 1600, text: shared)]
        let pairs = SpeakerBleedDeduper.pairsToDedup(segments: mics + systems, version: .v2)
        #expect(pairs.count == 1)
        #expect(pairs.first?.dedupedID == 1)
        #expect(pairs.first?.againstID == 2)
        #expect(pairs.first?.promotionReason == .pairwise)
    }

    // MARK: - Reset-first DB behaviour

    @Test func resetFirstNullsExistingFkBeforeReDeriving() async throws {
        // DB-driven: pre-populate a transcript_segments row with
        // `deduped_against_segment_id` already set. Call
        // SpeakerBleedDeduper.dedup. Verify the FK is wiped first
        // (regardless of whether the algorithm re-flags it).
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("execa-bleed-reset-\(UUID().uuidString).sqlite3")
        let database = try Execa.Database.make(at: tempURL)
        try await database.queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO meetings (id, title, started_at, status)
                VALUES ('m1', NULL, ?, 'ended')
                """,
                arguments: [Int64(Date().timeIntervalSince1970 * 1000)]
            )
            try db.execute(
                sql: """
                INSERT INTO speakers (id, meeting_id, source, raw_speaker_id, display_label)
                VALUES (10, 'm1', 'mic', 0, 'You'), (20, 'm1', 'system', 0, 'Remote')
                """
            )
            try db.execute(
                sql: """
                INSERT INTO transcript_segments
                    (id, meeting_id, speaker_id, start_ms, end_ms,
                     text, is_final, confidence, deduped_against_segment_id)
                VALUES
                    (100, 'm1', 10, 0, 2000, 'unrelated mic content here', 1, NULL, NULL),
                    (200, 'm1', 20, 0, 2000, 'completely different system content', 1, NULL, NULL)
                """
            )
            // Point mic 100's audit FK at system 200. Done as a
            // post-insert UPDATE so the FK reference is valid (it
            // can't be set in the same row's INSERT because 200
            // wouldn't exist yet at the per-row evaluation point —
            // and even multi-row INSERTs evaluate FKs eagerly with
            // `PRAGMA foreign_keys=ON`).
            try db.execute(
                sql: """
                UPDATE transcript_segments
                SET deduped_against_segment_id = 200
                WHERE id = 100
                """
            )
        }

        // Pre-condition: mic segment 100 has a stale audit FK at 200.
        let preFK: Int64?? = try await database.queue.read { db -> Int64?? in
            try Row.fetchOne(
                db,
                sql: "SELECT deduped_against_segment_id FROM transcript_segments WHERE id = ?",
                arguments: [100]
            ).map { $0["deduped_against_segment_id"] as Int64? }
        }
        try #require(preFK ?? nil == 200)

        // Run dedup. Mic and system text don't match, so no new
        // pair is produced — but the reset must still wipe the
        // stale FK to NULL.
        try await database.queue.write { db in
            _ = try SpeakerBleedDeduper.dedup(meetingID: "m1", version: .v2, in: db)
        }

        let postFK: Int64?? = try await database.queue.read { db -> Int64?? in
            try Row.fetchOne(
                db,
                sql: "SELECT deduped_against_segment_id FROM transcript_segments WHERE id = ?",
                arguments: [100]
            ).map { $0["deduped_against_segment_id"] as Int64? }
        }
        try #require(postFK != nil, "row should still exist")
        #expect(postFK ?? nil == nil, "reset-first must wipe stale FK regardless of re-derivation outcome")
    }
}
