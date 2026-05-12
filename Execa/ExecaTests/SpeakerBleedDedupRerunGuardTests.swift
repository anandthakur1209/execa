@testable import Execa
import Foundation
import GRDB
import Testing

/// Phase 3.5c commit (b) — Part 2 of the auto-rerun tests.
///
/// Verifies the guards baked into `DiarizationService.rerunDedupFor
/// Meeting`: the `auto_speaker_bleed_dedup` setting kills the pass
/// early when off, and the reset-first contract in
/// `SpeakerBleedDeduper.dedup` wipes stale FKs before re-derivation.
/// Helpers live in `SpeakerBleedDedupAutoRerunTests.swift`
/// (`enum RerunTestHelpers`) — shared across both files via internal
/// access to keep this struct's body under the line cap.
@MainActor
struct SpeakerBleedDedupRerunGuardTests {
    @Test func rerunRespectsAutoDedupSettingOff() async throws {
        // `auto_speaker_bleed_dedup = false` → `rerunDedupForMeeting`
        // returns early before touching the DB. Even a state that
        // SHOULD dedup stays untouched.
        let database = try RerunTestHelpers.tempDB()
        try await RerunTestHelpers.insertMeeting(database, id: "m1")
        let settings = SettingsStore(database: database)
        try await settings.setBool(false, forKey: .autoSpeakerBleedDedup)

        let micSpeaker = try await RerunTestHelpers.insertSpeaker(
            database, meetingID: "m1", source: "mic", rawSpeakerID: 0, label: "Anand"
        )
        let micSegment = try await RerunTestHelpers.insertSegment(
            database, meetingID: "m1", speakerID: micSpeaker, ms: (0, 2000),
            text: "alpha beta gamma delta epsilon"
        )
        let systemSpeaker = try await RerunTestHelpers.insertSpeaker(
            database, meetingID: "m1", source: "system", rawSpeakerID: 0, label: "Remote"
        )
        _ = try await RerunTestHelpers.insertSegment(
            database, meetingID: "m1", speakerID: systemSpeaker, ms: (0, 2000),
            text: "alpha beta gamma delta epsilon"
        )

        let standalone = await RerunTestHelpers.makeStandaloneService(database: database)
        await standalone.rerunDedupForMeeting(meetingID: "m1")

        let fk = try await RerunTestHelpers.dedupAuditFK(database, segmentID: micSegment)
        #expect(fk == nil,
                "setting OFF: rerun must be a no-op even with a flag-worthy state")
    }

    @Test func rerunResetsThenRederivesDedupState() async throws {
        // Reset-first contract from `SpeakerBleedDeduper.dedup`:
        // a stale audit FK from a prior topology gets cleared at the
        // top of the re-derivation, then the algorithm re-derives
        // the correct FK against the current topology. Test by
        // seeding a wrong FK on a segment that the algorithm would
        // flag correctly post-reset.
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

        // Seed a wrong FK — points at the unrelated system segment.
        try await RerunTestHelpers.setDedupAuditFK(
            database, segmentID: micSegment, targetID: unrelatedSegment
        )

        let standalone = await RerunTestHelpers.makeStandaloneService(database: database)
        await standalone.rerunDedupForMeeting(meetingID: "m1")

        let fk = try await RerunTestHelpers.dedupAuditFK(database, segmentID: micSegment)
        #expect(fk == matchingSegment,
                "reset-first: stale FK wiped, then re-derived to the true text match")
    }
}
