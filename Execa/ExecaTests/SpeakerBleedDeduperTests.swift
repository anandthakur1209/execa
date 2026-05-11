@testable import Execa
import Foundation
import Testing

/// Pure-function tests for `SpeakerBleedDeduper`. No DB hookup —
/// drives `pairsToDedup`, `timeOverlapFraction`, `jaccardTextSimilarity`,
/// `tokenize` directly with synthetic `Segment` arrays.
///
/// Phase 3.5b: tests forked into v1 (the Phase 3.5 Jaccard algorithm,
/// pinned forever — these tests exercise the `version: .v1` branch)
/// and v2 (Phase 3.5b containment + stemming + concat + cross-val,
/// lands across commits (b)/(c)/(d)). Regression tests at the bottom
/// pin both the v1 failure mode (30-token mic ⊂ 90-token system →
/// jaccard 0.33 → not flagged) and the v2 success (same input →
/// containment 1.0 → flagged). The v2 success test is
/// `@Test(.disabled)` in commit (a) and re-enabled in commit (b).
struct SpeakerBleedDeduperTests {
    private static func mic(id: Int64, start: Int, end: Int, text: String,
                            confidence: Double? = nil) -> SpeakerBleedDeduper.Segment {
        .init(id: id, speakerID: 100, source: "mic", startMs: start, endMs: end, text: text, confidence: confidence)
    }

    private static func sys(id: Int64, start: Int, end: Int, text: String,
                            confidence: Double? = nil) -> SpeakerBleedDeduper.Segment {
        .init(id: id, speakerID: 200, source: "system", startMs: start, endMs: end, text: text, confidence: confidence)
    }

    // MARK: - Time overlap (shared v1/v2)

    @Test func timeOverlapFractionAt49PercentBoundary() {
        // Mic 0–1000 ms (1000 ms duration). System 510–2000 ms (1490 ms
        // duration). Overlap is [510, 1000] = 490 ms. min(1000, 1490) =
        // 1000. Fraction = 0.49 — strictly below 0.5, should not dedup.
        let micSeg = Self.mic(id: 1, start: 0, end: 1000, text: "x")
        let systemSeg = Self.sys(id: 2, start: 510, end: 2000, text: "x")
        let fraction = SpeakerBleedDeduper.timeOverlapFraction(mic: micSeg, system: systemSeg)
        #expect(fraction < SpeakerBleedDeduper.minOverlapFraction, "fraction was \(fraction)")
    }

    @Test func timeOverlapFractionAt50PercentBoundary() {
        // Same shape but system 500–2000 → overlap [500, 1000] = 500 ms.
        // min(1000, 1500) = 1000. Fraction = 0.5 — exactly the
        // threshold; should dedup.
        let micSeg = Self.mic(id: 1, start: 0, end: 1000, text: "x")
        let systemSeg = Self.sys(id: 2, start: 500, end: 2000, text: "x")
        let fraction = SpeakerBleedDeduper.timeOverlapFraction(mic: micSeg, system: systemSeg)
        #expect(fraction >= SpeakerBleedDeduper.minOverlapFraction, "fraction was \(fraction)")
    }

    @Test func timeOverlapFractionWithZeroDurationIsZero() {
        let micSeg = Self.mic(id: 1, start: 1000, end: 1000, text: "x")
        let systemSeg = Self.sys(id: 2, start: 500, end: 1500, text: "x")
        #expect(SpeakerBleedDeduper.timeOverlapFraction(mic: micSeg, system: systemSeg) == 0)
    }

    // MARK: - Jaccard (v1 scoring; kept as audit-only in v2)

    @Test func jaccardSimilarityAt59PercentBoundary() {
        // 5 shared tokens out of 9 union = 5/9 ≈ 0.5555. Below 0.6,
        // should not dedup.
        let textA = "alpha beta gamma delta epsilon"
        let textB = "alpha beta gamma delta zeta eta theta"
        let sim = SpeakerBleedDeduper.jaccardTextSimilarity(textA, textB)
        #expect(sim < SpeakerBleedDeduper.minTextSimilarity, "similarity was \(sim)")
    }

    @Test func jaccardSimilarityAt60PercentBoundary() {
        // 3 shared tokens out of 5 union = 0.6 — exactly the threshold;
        // should dedup.
        let textA = "alpha beta gamma delta"
        let textB = "alpha beta gamma epsilon"
        // Tokens A: {alpha, beta, gamma, delta}; Tokens B: {alpha, beta,
        // gamma, epsilon}. Intersection = 3, union = 5. 3/5 = 0.6.
        let sim = SpeakerBleedDeduper.jaccardTextSimilarity(textA, textB)
        #expect(sim >= SpeakerBleedDeduper.minTextSimilarity, "similarity was \(sim)")
    }

    @Test func tokenizeHandlesPunctuationAndCase() {
        let mixedCase = SpeakerBleedDeduper.tokenize("Hello, World!")
        let plain = SpeakerBleedDeduper.tokenize("hello world")
        #expect(mixedCase == plain, "case + punctuation should produce same token set; got \(mixedCase) vs \(plain)")
    }

    @Test func tokenizeHandlesDevanagari() {
        let tokens = SpeakerBleedDeduper.tokenize("नमस्ते दुनिया")
        #expect(!tokens.isEmpty, "Devanagari text should produce non-empty tokens")
        // Sanity: same input should equal itself when re-tokenized.
        let again = SpeakerBleedDeduper.tokenize("नमस्ते दुनिया")
        #expect(tokens == again)
    }

    @Test func emptyTextProducesZeroJaccard() {
        #expect(SpeakerBleedDeduper.jaccardTextSimilarity("", "anything") == 0)
        #expect(SpeakerBleedDeduper.jaccardTextSimilarity("anything", "") == 0)
        #expect(SpeakerBleedDeduper.jaccardTextSimilarity("", "") == 0)
    }

    // MARK: - V1 pairsToDedup orchestration

    @Test func mirroredMicSystemFlaggedV1() {
        // Mic mirrors system: 90% overlap, identical text. Should flag
        // mic under v1.
        let mics = [Self.mic(id: 1, start: 100, end: 1500, text: "hello world from remote")]
        let systems = [Self.sys(id: 2, start: 0, end: 1600, text: "hello world from remote")]
        let pairs = SpeakerBleedDeduper.pairsToDedup(segments: mics + systems, version: .v1)
        #expect(pairs.count == 1)
        #expect(pairs.first?.dedupedID == 1)
        #expect(pairs.first?.againstID == 2)
        #expect(pairs.first?.promotionReason == .pairwise)
    }

    @Test func paraphraseNotFlaggedV1() {
        // Mic paraphrases system: time overlap is high but the
        // jaccard is low (different word choice).
        let mics = [Self.mic(id: 1, start: 0, end: 2000, text: "you mean to say their numbers improved")]
        let systems = [Self.sys(id: 2, start: 0, end: 2000, text: "the quarterly figures showed strong growth")]
        let pairs = SpeakerBleedDeduper.pairsToDedup(segments: mics + systems, version: .v1)
        #expect(pairs.isEmpty, "paraphrase should not be deduped; got \(pairs)")
    }

    @Test func subSecondMicSegmentSkippedV1() {
        let mics = [Self.mic(id: 1, start: 0, end: 999, text: "hello")]
        let systems = [Self.sys(id: 2, start: 0, end: 5000, text: "hello world")]
        let pairs = SpeakerBleedDeduper.pairsToDedup(segments: mics + systems, version: .v1)
        #expect(pairs.isEmpty)
    }

    @Test func subSecondSystemSegmentSkippedV1() {
        let mics = [Self.mic(id: 1, start: 0, end: 5000, text: "hello world")]
        let systems = [Self.sys(id: 2, start: 0, end: 999, text: "hello")]
        let pairs = SpeakerBleedDeduper.pairsToDedup(segments: mics + systems, version: .v1)
        #expect(pairs.isEmpty)
    }

    @Test func lowConfidenceMicSkippedV1() {
        let mics = [Self.mic(id: 1, start: 0, end: 1500, text: "hello world", confidence: 0.59)]
        let systems = [Self.sys(id: 2, start: 0, end: 1500, text: "hello world", confidence: 0.9)]
        let pairs = SpeakerBleedDeduper.pairsToDedup(segments: mics + systems, version: .v1)
        #expect(pairs.isEmpty)
    }

    @Test func nullConfidenceProceedsV1() {
        let mics = [Self.mic(id: 1, start: 0, end: 1500, text: "hello world", confidence: nil)]
        let systems = [Self.sys(id: 2, start: 0, end: 1500, text: "hello world", confidence: nil)]
        let pairs = SpeakerBleedDeduper.pairsToDedup(segments: mics + systems, version: .v1)
        #expect(pairs.count == 1)
    }

    @Test func emptyMicTextSkippedV1() {
        let mics = [Self.mic(id: 1, start: 0, end: 1500, text: "")]
        let systems = [Self.sys(id: 2, start: 0, end: 1500, text: "hello world")]
        let pairs = SpeakerBleedDeduper.pairsToDedup(segments: mics + systems, version: .v1)
        #expect(pairs.isEmpty)
    }

    @Test func singleSourceMeetingProducesNoPairsV1() {
        let mics = [Self.mic(id: 1, start: 0, end: 1500, text: "hello world")]
        let pairs = SpeakerBleedDeduper.pairsToDedup(segments: mics, version: .v1)
        #expect(pairs.isEmpty)
    }

    @Test func emptyMeetingProducesNoPairsV1() {
        let pairs = SpeakerBleedDeduper.pairsToDedup(segments: [], version: .v1)
        #expect(pairs.isEmpty)
    }

    @Test func micFlaggedAgainstFirstMatchingSystemOnlyV1() {
        let mics = [Self.mic(id: 1, start: 0, end: 2000, text: "hello world")]
        let systems = [
            Self.sys(id: 2, start: 0, end: 2000, text: "hello world"),
            Self.sys(id: 3, start: 0, end: 2000, text: "hello world")
        ]
        let pairs = SpeakerBleedDeduper.pairsToDedup(segments: mics + systems, version: .v1)
        #expect(pairs.count == 1)
        #expect(pairs.first?.dedupedID == 1)
        #expect(pairs.first?.againstID == 2, "should match first system segment, not second")
    }

    // MARK: - Regression: mic ⊂ system pattern (the v1→v2 motivation)

    @Test func regressionMicFragmentOfLongerSystemNotFlaggedInV1() {
        // The exact pattern from manual smoke that motivated Phase
        // 3.5b: 30 mic tokens, all present in a 90-token system
        // segment, at 90%+ time overlap. Jaccard = 30/90 = 0.33,
        // below 0.6 threshold → v1 correctly skips per its rule but
        // incorrectly leaves a visible duplicate. This test pins the
        // v1 failure mode forever — if a future maintainer "improves"
        // v1, this test surfaces the change.
        let micTokens = (1 ... 30).map { "tok\($0)" }
        let systemTokens = (1 ... 90).map { "tok\($0)" }
        let mics = [Self.mic(id: 1, start: 1000, end: 4000, text: micTokens.joined(separator: " "))]
        let systems = [Self.sys(id: 2, start: 0, end: 10000, text: systemTokens.joined(separator: " "))]
        let pairs = SpeakerBleedDeduper.pairsToDedup(segments: mics + systems, version: .v1)
        #expect(pairs.isEmpty, "v1's jaccard threshold does NOT flag this pattern; pinning the failure mode")
    }

    @Test func regressionMicFragmentOfLongerSystemFlaggedInV2() {
        // Same data as the v1 regression test above. Under v2,
        // containment = 30/30 = 1.0 ≥ 0.75 → flagged. The Phase 3.5b
        // proof point.
        let micTokens = (1 ... 30).map { "tok\($0)" }
        let systemTokens = (1 ... 90).map { "tok\($0)" }
        let mics = [Self.mic(id: 1, start: 1000, end: 4000, text: micTokens.joined(separator: " "))]
        let systems = [Self.sys(id: 2, start: 0, end: 10000, text: systemTokens.joined(separator: " "))]
        let pairs = SpeakerBleedDeduper.pairsToDedup(segments: mics + systems, version: .v2)
        #expect(pairs.count == 1, "v2's containment-based scoring SHOULD flag this pattern")
        #expect(pairs.first?.dedupedID == 1)
        #expect(pairs.first?.againstID == 2)
        #expect(pairs.first?.containment == 1.0)
        #expect(pairs.first?.promotionReason == .pairwise)
    }

    // MARK: - V2 containment boundaries

    @Test func containmentAt74PercentBoundary() {
        // Mic tokens: 100 unique, 74 shared with system. Containment
        // = 74/100 = 0.74 — strictly below 0.75, should NOT flag.
        let micTokens = (1 ... 100).map { "tok\($0)" }
        let systemTokens = (1 ... 74).map { "tok\($0)" } + (200 ... 226).map { "extra\($0)" }
        let containment = SpeakerBleedDeduper.containmentTextSimilarity(
            mic: micTokens.joined(separator: " "),
            system: systemTokens.joined(separator: " ")
        )
        #expect(containment < SpeakerBleedDeduper.minContainment, "containment was \(containment)")
    }

    @Test func containmentAt75PercentBoundary() {
        let micTokens = (1 ... 100).map { "tok\($0)" }
        let systemTokens = (1 ... 75).map { "tok\($0)" } + (200 ... 225).map { "extra\($0)" }
        let containment = SpeakerBleedDeduper.containmentTextSimilarity(
            mic: micTokens.joined(separator: " "),
            system: systemTokens.joined(separator: " ")
        )
        #expect(containment >= SpeakerBleedDeduper.minContainment, "containment was \(containment)")
    }

    @Test func containmentAtFullMatchIsOne() {
        let tokens = (1 ... 20).map { "tok\($0)" }.joined(separator: " ")
        let containment = SpeakerBleedDeduper.containmentTextSimilarity(mic: tokens, system: tokens)
        #expect(containment == 1.0)
    }

    @Test func containmentEmptyMicReturnsZero() {
        #expect(SpeakerBleedDeduper.containmentTextSimilarity(mic: "", system: "anything") == 0)
        #expect(SpeakerBleedDeduper.containmentTextSimilarity(mic: "", system: "") == 0)
    }

    // MARK: - V2 stemmer

    @Test func stemAppliesIesToY() {
        #expect(SpeakerBleedDeduper.stem("companies") == "company")
    }

    @Test func stemAppliesIedToY() {
        #expect(SpeakerBleedDeduper.stem("tried") == "try")
    }

    @Test func stemStripsIngWhenStemLongEnough() {
        #expect(SpeakerBleedDeduper.stem("training") == "train")
    }

    @Test func stemStripsEdWhenStemLongEnough() {
        #expect(SpeakerBleedDeduper.stem("trained") == "train")
    }

    @Test func stemStripsEsWhenStemLongEnough() {
        #expect(SpeakerBleedDeduper.stem("boxes") == "box")
    }

    @Test func stemStripsSWhenStemLongEnough() {
        #expect(SpeakerBleedDeduper.stem("scripts") == "script")
    }

    @Test func stemDoesNotOverStemShortWords() {
        // Min-stem guards protect these from catastrophic stripping.
        #expect(SpeakerBleedDeduper.stem("his") == "his", "s-rule blocked by min-stem")
        #expect(SpeakerBleedDeduper.stem("was") == "was", "s-rule blocked by min-stem")
        #expect(SpeakerBleedDeduper.stem("yes") == "yes", "es-rule blocked by min-stem")
        #expect(SpeakerBleedDeduper.stem("ring") == "ring", "ing-rule blocked by min-stem")
        #expect(SpeakerBleedDeduper.stem("fed") == "fed", "ed-rule blocked by min-stem")
        #expect(SpeakerBleedDeduper.stem("bed") == "bed", "ed-rule blocked by min-stem")
    }

    @Test func stemPassesThroughDevanagari() {
        // Non-ASCII tokens skip the stemmer entirely.
        #expect(SpeakerBleedDeduper.stem("नमस्ते") == "नमस्ते")
        #expect(SpeakerBleedDeduper.stem("दुनिया") == "दुनिया")
    }

    @Test func stemRulePrecedence_EsFiresBeforeSRule() {
        // "boxes" hits the es-rule (count 5 ≥ 5, post-strip len 3 ≥ 3)
        // → "box". If the s-rule had higher precedence, it would
        // strip only "s" → "boxe". The actual code order
        // (ies, ied, ing, ed, es, s) means es wins for "boxes".
        #expect(SpeakerBleedDeduper.stem("boxes") == "box")
    }

    @Test func stemDoesNotStemFourLetterUses() {
        // "uses" (4 chars) is too short for any rule to fire safely:
        // both s-rule (input ≥ 5) and es-rule (input ≥ 5) block on
        // the input-length guard. Pass-through is correct —
        // over-stemming to "us" or "use" without a word-list lookup
        // would be a heuristic too aggressive for our domain.
        #expect(SpeakerBleedDeduper.stem("uses") == "uses")
    }

    @Test func tokenListAppliesStemming() {
        // Surface-form drift: "training scripts" tokenized + stemmed
        // → ["train", "script"]. Matches the v2 motivation.
        let tokens = SpeakerBleedDeduper.tokenList("Training scripts")
        #expect(tokens == ["train", "script"])
    }

    // MARK: - V2 pairwise behaviour

    @Test func paraphraseStillNotFlaggedInV2() {
        // Phase 3.5 false-positive guard: legitimately different word
        // choice at high time overlap stays not-flagged under v2 too.
        // Tokenized & stemmed text shares few tokens → containment is
        // low even though Jaccard would be irrelevant.
        let mics = [Self.mic(id: 1, start: 0, end: 2000, text: "you mean to say their numbers improved")]
        let systems = [Self.sys(id: 2, start: 0, end: 2000, text: "the quarterly figures showed strong growth")]
        let pairs = SpeakerBleedDeduper.pairsToDedup(segments: mics + systems, version: .v2)
        #expect(pairs.isEmpty, "paraphrase should not be deduped under v2; got \(pairs)")
    }

    @Test func highContainmentLowOverlapNotFlaggedInV2() {
        // Containment 1.0 but time-overlap below the 0.5 floor → not
        // flagged. The overlap floor is the shared gate across v1/v2.
        // Mic 0–1000 (1 s); system 700–10000 (9.3 s). Overlap = 300 ms
        // / min(1000, 9300) = 300/1000 = 0.3 → below 0.5.
        let micTokens = (1 ... 20).map { "tok\($0)" }
        let systemTokens = (1 ... 20).map { "tok\($0)" } + (100 ... 200).map { "filler\($0)" }
        let mics = [Self.mic(id: 1, start: 0, end: 1000, text: micTokens.joined(separator: " "))]
        let systems = [Self.sys(id: 2, start: 700, end: 10000, text: systemTokens.joined(separator: " "))]
        let pairs = SpeakerBleedDeduper.pairsToDedup(segments: mics + systems, version: .v2)
        #expect(pairs.isEmpty, "containment alone shouldn't flag; overlap floor still gates")
    }

    @Test func v2CarriesBothScoresInAudit() throws {
        // Audit symmetry: v2 pairs record both containment (the
        // decision) and jaccard (informational only). v1 pairs leave
        // containment nil and record jaccard.
        let micTokens = (1 ... 30).map { "tok\($0)" }
        let systemTokens = (1 ... 30).map { "tok\($0)" }
        let mics = [Self.mic(id: 1, start: 0, end: 2000, text: micTokens.joined(separator: " "))]
        let systems = [Self.sys(id: 2, start: 0, end: 2000, text: systemTokens.joined(separator: " "))]
        let pairs = SpeakerBleedDeduper.pairsToDedup(segments: mics + systems, version: .v2)
        try #require(pairs.count == 1)
        #expect(pairs.first?.containment == 1.0)
        #expect(pairs.first?.jaccard == 1.0)
    }

    // V2 concatenation pre-pass tests live in
    // `SpeakerBleedDedupV2ConcatenationTests.swift` to keep this file
    // under the type/file-length caps.
}
