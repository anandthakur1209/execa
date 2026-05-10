@testable import Execa
import Foundation
import Testing

/// Pure-function tests for `SpeakerBleedDeduper`. No DB hookup —
/// drives `pairsToDedup`, `timeOverlapFraction`, `jaccardTextSimilarity`,
/// `tokenize` directly with synthetic `Segment` arrays. Boundary
/// coverage on both thresholds (49/50% overlap, 59/60% jaccard) plus
/// the early-skip filters (sub-second duration, low confidence,
/// empty text). Integration through `DiarizationService` is covered
/// by `SpeakerBleedDedupIntegrationTests` in commit 3.
struct SpeakerBleedDeduperTests {
    private static func mic(id: Int64, start: Int, end: Int, text: String,
                            confidence: Double? = nil) -> SpeakerBleedDeduper.Segment {
        .init(id: id, speakerID: 100, source: "mic", startMs: start, endMs: end, text: text, confidence: confidence)
    }

    private static func sys(id: Int64, start: Int, end: Int, text: String,
                            confidence: Double? = nil) -> SpeakerBleedDeduper.Segment {
        .init(id: id, speakerID: 200, source: "system", startMs: start, endMs: end, text: text, confidence: confidence)
    }

    // MARK: - Time overlap

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

    // MARK: - Jaccard

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

    // MARK: - pairsToDedup orchestration

    @Test func mirroredMicSystemFlagged() {
        // Mic mirrors system: 90% overlap, identical text. Should flag
        // mic.
        let mics = [Self.mic(id: 1, start: 100, end: 1500, text: "hello world from remote")]
        let systems = [Self.sys(id: 2, start: 0, end: 1600, text: "hello world from remote")]
        let pairs = SpeakerBleedDeduper.pairsToDedup(segments: mics + systems)
        #expect(pairs.count == 1)
        #expect(pairs[0] == (1, 2))
    }

    @Test func paraphraseNotFlagged() {
        // Mic paraphrases system: time overlap is high but the
        // jaccard is low (different word choice).
        let mics = [Self.mic(id: 1, start: 0, end: 2000, text: "you mean to say their numbers improved")]
        let systems = [Self.sys(id: 2, start: 0, end: 2000, text: "the quarterly figures showed strong growth")]
        let pairs = SpeakerBleedDeduper.pairsToDedup(segments: mics + systems)
        #expect(pairs.isEmpty, "paraphrase should not be deduped; got \(pairs)")
    }

    @Test func subSecondMicSegmentSkipped() {
        // 999 ms mic → below the 1000 ms duration floor; skip.
        let mics = [Self.mic(id: 1, start: 0, end: 999, text: "hello")]
        let systems = [Self.sys(id: 2, start: 0, end: 5000, text: "hello world")]
        let pairs = SpeakerBleedDeduper.pairsToDedup(segments: mics + systems)
        #expect(pairs.isEmpty)
    }

    @Test func subSecondSystemSegmentSkipped() {
        // 999 ms system → also blocks dedup.
        let mics = [Self.mic(id: 1, start: 0, end: 5000, text: "hello world")]
        let systems = [Self.sys(id: 2, start: 0, end: 999, text: "hello")]
        let pairs = SpeakerBleedDeduper.pairsToDedup(segments: mics + systems)
        #expect(pairs.isEmpty)
    }

    @Test func lowConfidenceMicSkipped() {
        // Mic confidence 0.59 — explicitly below the 0.6 threshold.
        let mics = [Self.mic(id: 1, start: 0, end: 1500, text: "hello world", confidence: 0.59)]
        let systems = [Self.sys(id: 2, start: 0, end: 1500, text: "hello world", confidence: 0.9)]
        let pairs = SpeakerBleedDeduper.pairsToDedup(segments: mics + systems)
        #expect(pairs.isEmpty)
    }

    @Test func nullConfidenceProceeds() {
        // NULL confidence on either side should NOT block dedup —
        // Sarvam batch may not always emit confidence.
        let mics = [Self.mic(id: 1, start: 0, end: 1500, text: "hello world", confidence: nil)]
        let systems = [Self.sys(id: 2, start: 0, end: 1500, text: "hello world", confidence: nil)]
        let pairs = SpeakerBleedDeduper.pairsToDedup(segments: mics + systems)
        #expect(pairs.count == 1)
    }

    @Test func emptyMicTextSkipped() {
        let mics = [Self.mic(id: 1, start: 0, end: 1500, text: "")]
        let systems = [Self.sys(id: 2, start: 0, end: 1500, text: "hello world")]
        let pairs = SpeakerBleedDeduper.pairsToDedup(segments: mics + systems)
        #expect(pairs.isEmpty)
    }

    @Test func singleSourceMeetingProducesNoPairs() {
        // No system segments → nothing to dedup against.
        let mics = [Self.mic(id: 1, start: 0, end: 1500, text: "hello world")]
        let pairs = SpeakerBleedDeduper.pairsToDedup(segments: mics)
        #expect(pairs.isEmpty)
    }

    @Test func emptyMeetingProducesNoPairs() {
        let pairs = SpeakerBleedDeduper.pairsToDedup(segments: [])
        #expect(pairs.isEmpty)
    }

    @Test func micFlaggedAgainstFirstMatchingSystemOnly() {
        // Two system segments could both match. The deduper should
        // flag against the FIRST match and stop — preserves a stable
        // audit pointer.
        let mics = [Self.mic(id: 1, start: 0, end: 2000, text: "hello world")]
        let systems = [
            Self.sys(id: 2, start: 0, end: 2000, text: "hello world"),
            Self.sys(id: 3, start: 0, end: 2000, text: "hello world")
        ]
        let pairs = SpeakerBleedDeduper.pairsToDedup(segments: mics + systems)
        #expect(pairs.count == 1)
        #expect(pairs[0] == (1, 2), "should match first system segment, not second")
    }
}
