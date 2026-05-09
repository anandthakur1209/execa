@testable import Execa
import Foundation
import GRDB
import Testing

/// BUG 8 regression coverage: Sarvam batch returns speaker IDs that
/// aren't reliably 0-indexed (a single mic speaker can come back as
/// `speaker_id=1`, leaving no `(mic, 0)` row and silently breaking
/// Decision 17). The swap now renumbers per source to 0-indexed,
/// sorted by earliest segment `start_ms`. Both of the first two tests
/// here would have caught BUG 8 directly; the tie-breaker test pins
/// the determinism contract for overlapping start_ms.
///
/// Reuses `DiarizationTestEnv` from `DiarizationServiceTests.swift`.
struct DiarizationServiceRenumberingTests {
    @Test func batchSpeakerIDsRenumberedTo0Indexed() async throws {
        let env = try await DiarizationTestEnv.make(displayName: "Anand")
        try await env.seedStreaming(
            source: "mic", rawSpeakerID: 0, label: "Anand", text: "s"
        )
        // Mic Sarvam IDs [3, 7, 12] in order of first appearance
        // (start_ms 100, 500, 1000). System Sarvam IDs [1, 5] in
        // first-appearance order (200, 800).
        await env.run(
            mic: .success(SarvamBatchResult(segments: [
                .init(speakerID: 3, startMs: 100, endMs: 400, text: "first-mic", languageCode: "en-IN"),
                .init(speakerID: 7, startMs: 500, endMs: 900, text: "second-mic", languageCode: "en-IN"),
                .init(speakerID: 12, startMs: 1000, endMs: 1500, text: "third-mic", languageCode: "en-IN")
            ])),
            system: .success(SarvamBatchResult(segments: [
                .init(speakerID: 1, startMs: 200, endMs: 700, text: "first-system", languageCode: "en-IN"),
                .init(speakerID: 5, startMs: 800, endMs: 1200, text: "second-system", languageCode: "en-IN")
            ]))
        )

        // Mic raw IDs are 0/1/2 in first-appearance order; system 0/1.
        let speakers = try await env.allSpeakers()
        try #require(speakers.count == 5, "got \(speakers)")
        #expect(speakers[0] == ["mic", "0", "Anand"])
        #expect(speakers[1] == ["mic", "1", "In-room 2"])
        #expect(speakers[2] == ["mic", "2", "In-room 3"])
        #expect(speakers[3] == ["system", "0", "Speaker 1"])
        #expect(speakers[4] == ["system", "1", "Speaker 2"])

        // Segments resolve to the renumbered speakers via the
        // FK — text/start ordering preserved.
        let texts = try await env.segmentTexts()
        #expect(texts == ["first-mic", "first-system", "second-mic", "second-system", "third-mic"],
                "segments should land in start_ms order across sources")
    }

    @Test func decision17PreservationWithNonZeroIndexedBatch() async throws {
        // The exact BUG 8 repro: user renames `(mic, 0)` mid-meeting
        // ("RenamedAnand"), Sarvam returns the single speaker as
        // `speaker_id=5`, post-swap there must still be a `(mic, 0)`
        // row carrying the preserved label.
        let env = try await DiarizationTestEnv.make(displayName: "Anand")
        try await env.seedStreaming(
            source: "mic", rawSpeakerID: 0, label: "RenamedAnand", text: "s"
        )

        await env.run(
            mic: .success(SarvamBatchResult(segments: [
                .init(speakerID: 5, startMs: 0, endMs: 5000, text: "spoken text", languageCode: "en-IN")
            ])),
            system: .success(SarvamBatchResult(segments: []))
        )

        // Post-swap: `(mic, 0)` exists and carries the preserved
        // label, not the displayName default.
        #expect(try await env.label(source: "mic", rawSpeakerID: 0) == "RenamedAnand")
        // No `(mic, 5)` row: Sarvam's ID was renumbered to 0.
        #expect(try await env.label(source: "mic", rawSpeakerID: 5) == nil)
    }

    @Test func renumberingIsStableForTiedStartTimes() async throws {
        // If two speakers' earliest segments share the same
        // start_ms (rare but possible — overlapping utterances or
        // 0-start system audio), the tie-breaker is the original
        // Sarvam ID ascending so the renumbering is deterministic.
        let env = try await DiarizationTestEnv.make(displayName: "Anand")
        try await env.seedStreaming(
            source: "mic", rawSpeakerID: 0, label: "Anand", text: "s"
        )
        await env.run(
            mic: .success(SarvamBatchResult(segments: [
                .init(speakerID: 9, startMs: 0, endMs: 1000, text: "via-9", languageCode: "en-IN"),
                .init(speakerID: 2, startMs: 0, endMs: 1500, text: "via-2", languageCode: "en-IN")
            ])),
            system: .success(SarvamBatchResult(segments: []))
        )
        // Both at start_ms=0; Sarvam ID 2 < 9 so 2 wins position 0.
        // displayName default applies to (mic, 0) since the seeded
        // label "Anand" matches displayName, no preservation kicks in.
        let speakers = try await env.allSpeakers()
        #expect(speakers.count == 2)
        #expect(speakers[0] == ["mic", "0", "Anand"])
        #expect(speakers[1] == ["mic", "1", "In-room 2"])
    }
}
