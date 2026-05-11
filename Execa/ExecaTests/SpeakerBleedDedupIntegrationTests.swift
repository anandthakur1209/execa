@testable import Execa
import Foundation
import GRDB
import Testing

/// DB-driven integration tests for the Phase 3.5 speaker-bleed dedup
/// pass. Exercises the full pipeline: synthetic streaming-time
/// state seeded into DB, `DiarizationService.runForMeeting` invoked
/// with mocked batch results that produce a mirror pattern, post-
/// dedup DB state asserted on `transcript_segments.
/// deduped_against_segment_id` and on `SpeakerQueries.visibleSpeakers`
/// to confirm orphan mic speakers drop out of the visible list.
///
/// Distinct from `SpeakerBleedDeduperTests` which exercises the
/// pure-function algorithm in isolation; this suite asserts that the
/// algorithm is wired into the swap pipeline correctly and that view
/// queries honour the soft-delete column.
struct SpeakerBleedDedupIntegrationTests {
    @Test func synthMirroredMeetingDeduped() async throws {
        // Mic-batch and system-batch return identical text at
        // overlapping times — the BUG-level bleed pattern from Test 1.
        let env = try await DiarizationTestEnv.make(displayName: "Anand")
        try await env.seedStreaming(source: "mic", rawSpeakerID: 0, label: "Anand", text: "stream-mic")
        try await env.seedStreaming(source: "system", rawSpeakerID: 0, label: "Remote", text: "stream-system")

        await env.run(
            mic: .success(SarvamBatchResult(segments: [
                .init(speakerID: 0, startMs: 0, endMs: 3000,
                      text: "hello world from the remote speaker", languageCode: "en-IN")
            ])),
            system: .success(SarvamBatchResult(segments: [
                .init(speakerID: 0, startMs: 0, endMs: 3000,
                      text: "hello world from the remote speaker", languageCode: "en-IN")
            ]))
        )

        // Both segments physically exist; the mic-side carries the
        // audit FK pointing at the system-side ID.
        let allSegments = try await env.allSegmentsWithDedupAudit()
        try #require(allSegments.count == 2)
        let micSegment = try #require(allSegments.first { $0.source == "mic" })
        let systemSegment = try #require(allSegments.first { $0.source == "system" })
        let actualAudit = micSegment.dedupedAgainstSegmentID ?? -1
        #expect(micSegment.dedupedAgainstSegmentID == systemSegment.id,
                "mic-side should be deduped against system-side id; got \(actualAudit)")
        #expect(systemSegment.dedupedAgainstSegmentID == nil)

        // The orphan mic speaker is physically present but filtered
        // out of `visibleSpeakers`.
        let visibleSpeakers = try await env.visibleSpeakerSummaries()
        #expect(visibleSpeakers.count == 1, "only system-side should be visible; got \(visibleSpeakers)")
        #expect(visibleSpeakers.first?.source == "system")
    }

    @Test func legitimateOverlapNotDeduped() async throws {
        // Phase 3.5 plan Meeting 3: system-side remote speaker says
        // X; mic-side user paraphrases X at overlapping times.
        // Different word choice → jaccard < 60% → both turns visible.
        let env = try await DiarizationTestEnv.make(displayName: "Anand")
        try await env.seedStreaming(source: "mic", rawSpeakerID: 0, label: "Anand", text: "stream-mic")
        try await env.seedStreaming(source: "system", rawSpeakerID: 0, label: "Remote", text: "stream-system")

        await env.run(
            mic: .success(SarvamBatchResult(segments: [
                .init(speakerID: 0, startMs: 100, endMs: 3000,
                      text: "you mean to say their numbers improved",
                      languageCode: "en-IN")
            ])),
            system: .success(SarvamBatchResult(segments: [
                .init(speakerID: 0, startMs: 0, endMs: 2900,
                      text: "the quarterly figures showed strong growth",
                      languageCode: "en-IN")
            ]))
        )

        // Both segments visible; no audit FKs populated.
        let allSegments = try await env.allSegmentsWithDedupAudit()
        try #require(allSegments.count == 2)
        for segment in allSegments {
            #expect(segment.dedupedAgainstSegmentID == nil,
                    "paraphrase should not be deduped; segment \(segment.id) has audit \(segment.dedupedAgainstSegmentID ?? -1)")
        }
        let visibleSpeakers = try await env.visibleSpeakerSummaries()
        #expect(visibleSpeakers.count == 2)
    }

    @Test func singleSourceMeetingNoOp() async throws {
        // Mic-only — no system-side to dedup against. Mic segment
        // stays; no audit FK populated.
        let env = try await DiarizationTestEnv.make(displayName: "Anand")
        try await env.seedStreaming(source: "mic", rawSpeakerID: 0, label: "Anand", text: "stream-mic")

        await env.run(
            mic: .success(SarvamBatchResult(segments: [
                .init(speakerID: 0, startMs: 0, endMs: 2000,
                      text: "hello world", languageCode: "en-IN")
            ])),
            system: .success(SarvamBatchResult(segments: []))
        )

        let allSegments = try await env.allSegmentsWithDedupAudit()
        try #require(allSegments.count == 1)
        #expect(allSegments[0].dedupedAgainstSegmentID == nil)
    }

    @Test func emptyMeetingNoOp() async throws {
        // No streaming state → DiarizationService skips entirely
        // (edge case A from Phase 3 commit 4); dedup never runs.
        let env = try await DiarizationTestEnv.make(displayName: "Anand")
        await env.run(
            mic: .success(SarvamBatchResult(segments: [])),
            system: .success(SarvamBatchResult(segments: []))
        )
        let allSegments = try await env.allSegmentsWithDedupAudit()
        #expect(allSegments.isEmpty)
    }

    @Test func flagOffSkipsDedup() async throws {
        // auto_speaker_bleed_dedup=false → mic segment survives
        // bleed, both speakers visible. Phase 3 behavior.
        let env = try await DiarizationTestEnv.make(displayName: "Anand")
        try await env.settings.setBool(false, forKey: .autoSpeakerBleedDedup)
        try await env.seedStreaming(source: "mic", rawSpeakerID: 0, label: "Anand", text: "stream-mic")
        try await env.seedStreaming(source: "system", rawSpeakerID: 0, label: "Remote", text: "stream-system")

        await env.run(
            mic: .success(SarvamBatchResult(segments: [
                .init(speakerID: 0, startMs: 0, endMs: 3000,
                      text: "hello world from the remote speaker", languageCode: "en-IN")
            ])),
            system: .success(SarvamBatchResult(segments: [
                .init(speakerID: 0, startMs: 0, endMs: 3000,
                      text: "hello world from the remote speaker", languageCode: "en-IN")
            ]))
        )

        let allSegments = try await env.allSegmentsWithDedupAudit()
        try #require(allSegments.count == 2)
        for segment in allSegments {
            #expect(segment.dedupedAgainstSegmentID == nil,
                    "flag off should leave both segments un-deduped")
        }
        let visibleSpeakers = try await env.visibleSpeakerSummaries()
        #expect(visibleSpeakers.count == 2, "both sides should be visible when dedup is disabled")
    }

    @Test func orphanMicSpeakerHiddenInSidebar() async throws {
        // Same setup as `synthMirroredMeetingDeduped` but the
        // assertion focuses on `SpeakerQueries.visibleSpeakers` —
        // the single source of truth for both SpeakerSidebar.derive
        // and MeetingDetailView.loadSpeakerRows. Confirms the orphan
        // filter actually drops the mic-side row.
        let env = try await DiarizationTestEnv.make(displayName: "Anand")
        try await env.seedStreaming(source: "mic", rawSpeakerID: 0, label: "Anand", text: "stream-mic")
        try await env.seedStreaming(source: "system", rawSpeakerID: 0, label: "Remote", text: "stream-system")

        await env.run(
            mic: .success(SarvamBatchResult(segments: [
                .init(speakerID: 0, startMs: 0, endMs: 3000,
                      text: "hello world from the remote speaker", languageCode: "en-IN")
            ])),
            system: .success(SarvamBatchResult(segments: [
                .init(speakerID: 0, startMs: 0, endMs: 3000,
                      text: "hello world from the remote speaker", languageCode: "en-IN")
            ]))
        )

        // The mic-side speakers row exists in DB.
        let allSpeakerCount = try await env.totalSpeakerCount()
        #expect(allSpeakerCount == 2, "physical rows still present in `speakers`")
        // But the visible-speakers query filters it out.
        let visibleSpeakers = try await env.visibleSpeakerSummaries()
        #expect(visibleSpeakers.count == 1)
        #expect(visibleSpeakers.first?.source == "system",
                "only system-side speaker should be visible after dedup")
    }

    @Test func v2CrossValidationPromotionFlagsRemainingSegmentEndToEnd() async throws {
        // Phase 3.5b commit (d) end-to-end: 4 of 5 mic-speaker
        // segments flag pairwise; the 5th has unrelated text but
        // gets promoted by cross-validation (ratio 0.8 ≥ 0.8,
        // count 4 ≥ 3). Audit FK on the promoted row points at the
        // nearest-neighbor system segment within the target system
        // speaker.
        let env = try await DiarizationTestEnv.make(displayName: "Anand")
        try await env.seedStreaming(source: "mic", rawSpeakerID: 0, label: "Anand", text: "stream-mic")
        try await env.seedStreaming(source: "system", rawSpeakerID: 0, label: "Remote", text: "stream-system")
        let sharedTokens = (1 ... 10).map { "tok\($0)" }.joined(separator: " ")
        await env.run(
            mic: .success(SarvamBatchResult(segments: [
                .init(speakerID: 0, startMs: 0, endMs: 1500, text: sharedTokens, languageCode: "en-IN"),
                .init(speakerID: 0, startMs: 2000, endMs: 3500, text: sharedTokens, languageCode: "en-IN"),
                .init(speakerID: 0, startMs: 4000, endMs: 5500, text: sharedTokens, languageCode: "en-IN"),
                .init(speakerID: 0, startMs: 6000, endMs: 7500, text: sharedTokens, languageCode: "en-IN"),
                .init(speakerID: 0, startMs: 20000, endMs: 21000,
                      text: "unrelated promoted text bleed", languageCode: "en-IN")
            ])),
            system: .success(SarvamBatchResult(segments: [
                .init(speakerID: 0, startMs: 0, endMs: 1500, text: sharedTokens, languageCode: "en-IN"),
                .init(speakerID: 0, startMs: 2000, endMs: 3500, text: sharedTokens, languageCode: "en-IN"),
                .init(speakerID: 0, startMs: 4000, endMs: 5500, text: sharedTokens, languageCode: "en-IN"),
                .init(speakerID: 0, startMs: 6000, endMs: 7500, text: sharedTokens, languageCode: "en-IN"),
                .init(speakerID: 0, startMs: 19000, endMs: 22000, text: sharedTokens, languageCode: "en-IN")
            ]))
        )

        let segments = try await env.allSegmentsWithDedupAudit()
        let micSegments = segments.filter { $0.source == "mic" }
        try #require(micSegments.count == 5)
        for segment in micSegments {
            #expect(segment.dedupedAgainstSegmentID != nil,
                    "all 5 mic segments should be flagged (4 pairwise + 1 promoted)")
        }
        let visibleSpeakers = try await env.visibleSpeakerSummaries()
        #expect(visibleSpeakers.count == 1)
        #expect(visibleSpeakers.first?.source == "system")
    }

    @Test func v2ConcatenationPrePassFlagsFragmentsEndToEnd() async throws {
        // Phase 3.5b commit (c) end-to-end: mic produces three short
        // fragments inside one long system utterance. Each fragment
        // is individually below containment threshold; the concat
        // pre-pass joins them and flags all three. Verifies the
        // algorithm wires through to the DB audit column under v2.
        let env = try await DiarizationTestEnv.make(displayName: "Anand")
        try await env.seedStreaming(source: "mic", rawSpeakerID: 0, label: "Anand", text: "stream-mic")
        try await env.seedStreaming(source: "system", rawSpeakerID: 0, label: "Remote", text: "stream-system")

        await env.run(
            mic: .success(SarvamBatchResult(segments: [
                .init(speakerID: 0, startMs: 500, endMs: 1100,
                      text: "alpha beta gamma", languageCode: "en-IN"),
                .init(speakerID: 0, startMs: 1500, endMs: 2100,
                      text: "delta epsilon zeta", languageCode: "en-IN"),
                .init(speakerID: 0, startMs: 2500, endMs: 3100,
                      text: "eta theta iota", languageCode: "en-IN")
            ])),
            system: .success(SarvamBatchResult(segments: [
                .init(speakerID: 0, startMs: 0, endMs: 5000,
                      text: "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu",
                      languageCode: "en-IN")
            ]))
        )

        let segments = try await env.allSegmentsWithDedupAudit()
        let micSegments = segments.filter { $0.source == "mic" }
        try #require(micSegments.count == 3, "three mic fragments persisted")
        for segment in micSegments {
            #expect(segment.dedupedAgainstSegmentID != nil,
                    "concat pre-pass should flag every fragment")
        }
        // System-side stays visible.
        let systemSegments = segments.filter { $0.source == "system" }
        #expect(systemSegments.first?.dedupedAgainstSegmentID == nil)
        // Sidebar filters out the orphan mic speaker.
        let visibleSpeakers = try await env.visibleSpeakerSummaries()
        #expect(visibleSpeakers.count == 1)
        #expect(visibleSpeakers.first?.source == "system")
    }
}

// MARK: - Test env extensions

extension DiarizationTestEnv {
    /// One row of `transcript_segments` with the audit FK exposed.
    struct AuditedSegment {
        let id: Int64
        let source: String
        let dedupedAgainstSegmentID: Int64?
    }

    /// All non-merged-out segments in the meeting, with the audit
    /// FK column.
    func allSegmentsWithDedupAudit() async throws -> [AuditedSegment] {
        try await database.queue.read { db -> [AuditedSegment] in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT t.id AS id,
                       s.source AS source,
                       t.deduped_against_segment_id AS deduped_against
                FROM transcript_segments t
                JOIN speakers s ON s.id = t.speaker_id
                WHERE t.meeting_id = ? AND t.is_final = 1
                ORDER BY s.source, t.start_ms
                """,
                arguments: [self.meetingID]
            )
            return rows.compactMap { row in
                guard let id: Int64 = row["id"], let source: String = row["source"] else {
                    return nil
                }
                return AuditedSegment(
                    id: id,
                    source: source,
                    dedupedAgainstSegmentID: row["deduped_against"]
                )
            }
        }
    }

    /// Just the source field of every visible speaker, so tests can
    /// assert on the post-dedup speaker set without mocking the full
    /// SwiftUI view-model.
    struct VisibleSpeakerSummary {
        let id: Int64
        let source: String
    }

    func visibleSpeakerSummaries() async throws -> [VisibleSpeakerSummary] {
        try await database.queue.read { db in
            let rows = try SpeakerQueries.visibleSpeakers(
                meetingID: self.meetingID,
                in: db
            )
            return rows.compactMap { row in
                guard let id: Int64 = row["id"], let source: String = row["source"] else {
                    return nil
                }
                return VisibleSpeakerSummary(id: id, source: source)
            }
        }
    }

    func totalSpeakerCount() async throws -> Int {
        try await database.queue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM speakers WHERE meeting_id = ?",
                arguments: [self.meetingID]
            ) ?? 0
        }
    }
}
