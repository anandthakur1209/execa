@testable import Execa
import Foundation
import Testing

/// Phase 3.5b commit (c) tests for `SpeakerBleedDeduper`'s
/// concatenation pre-pass. Split out of
/// `SpeakerBleedDeduperTests.swift` to keep each file + struct body
/// under the lint caps.
struct SpeakerBleedDedupV2ConcatenationTests {
    private static func mic(
        id: Int64,
        start: Int,
        end: Int,
        text: String,
        speakerID: Int64 = 100,
        confidence: Double? = nil
    ) -> SpeakerBleedDeduper.Segment {
        .init(id: id, speakerID: speakerID, source: "mic",
              startMs: start, endMs: end, text: text, confidence: confidence)
    }

    private static func sys(
        id: Int64,
        start: Int,
        end: Int,
        text: String,
        confidence: Double? = nil
    ) -> SpeakerBleedDeduper.Segment {
        .init(id: id, speakerID: 200, source: "system",
              startMs: start, endMs: end, text: text, confidence: confidence)
    }

    @Test func concatenationPrePassFlagsThreeFragments() throws {
        // Three same-speaker mic fragments inside one long system
        // segment. Each fragment is individually below containment
        // threshold; joined together they cover the system tokens at
        // 100% containment. All three flagged via `.concatenation`.
        let mics = [
            Self.mic(id: 1, start: 500, end: 1100, text: "alpha beta gamma"),
            Self.mic(id: 2, start: 1500, end: 2100, text: "delta epsilon zeta"),
            Self.mic(id: 3, start: 2500, end: 3100, text: "eta theta iota")
        ]
        let systems = [Self.sys(
            id: 99, start: 0, end: 5000,
            text: "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda"
        )]
        let pairs = SpeakerBleedDeduper.pairsFromConcatenationPrePass(
            mics: mics, systems: systems
        )
        try #require(pairs.count == 3, "all three fragments should flag")
        for pair in pairs {
            #expect(pair.againstID == 99)
            #expect(pair.promotionReason == .concatenation)
        }
        #expect(Set(pairs.map(\.dedupedID)) == [1, 2, 3])
    }

    @Test func concatenationSkipsAlternatingSpeakers() {
        // Speaker A, speaker B, speaker A inside one long system →
        // no group of size ≥ 2 for either speaker.
        let mics = [
            Self.mic(id: 1, start: 100, end: 700, text: "alpha beta", speakerID: 100),
            Self.mic(id: 2, start: 1000, end: 1600, text: "gamma delta", speakerID: 200),
            Self.mic(id: 3, start: 2000, end: 2600, text: "epsilon zeta", speakerID: 100)
        ]
        let systems = [Self.sys(id: 99, start: 0, end: 5000,
                                text: "alpha beta gamma delta epsilon zeta")]
        let pairs = SpeakerBleedDeduper.pairsFromConcatenationPrePass(
            mics: mics, systems: systems
        )
        #expect(pairs.isEmpty, "alternating speakers should not form a concat group")
    }

    @Test func concatenationGroupSubSecondTotalSkipped() {
        let mics = [
            Self.mic(id: 1, start: 100, end: 300, text: "alpha"),
            Self.mic(id: 2, start: 400, end: 600, text: "beta"),
            Self.mic(id: 3, start: 700, end: 900, text: "gamma")
        ]
        let systems = [Self.sys(id: 99, start: 0, end: 5000, text: "alpha beta gamma delta")]
        let pairs = SpeakerBleedDeduper.pairsFromConcatenationPrePass(
            mics: mics, systems: systems
        )
        #expect(pairs.isEmpty)
    }

    @Test func concatenationGroupLowConfidenceSkipped() {
        // Min non-NULL confidence 0.5 < 0.6 → ineligible.
        let mics = [
            Self.mic(id: 1, start: 0, end: 600, text: "alpha beta", confidence: 0.5),
            Self.mic(id: 2, start: 700, end: 1300, text: "gamma delta", confidence: 0.9)
        ]
        let systems = [Self.sys(id: 99, start: 0, end: 5000, text: "alpha beta gamma delta")]
        let pairs = SpeakerBleedDeduper.pairsFromConcatenationPrePass(
            mics: mics, systems: systems
        )
        #expect(pairs.isEmpty)
    }

    @Test func concatenationGroupSpansMultipleSystemsSkipped() {
        // Group spans 0–3000; no single system entirely contains it.
        let mics = [
            Self.mic(id: 1, start: 0, end: 600, text: "alpha beta"),
            Self.mic(id: 2, start: 2000, end: 3000, text: "gamma delta")
        ]
        let systems = [
            Self.sys(id: 99, start: 0, end: 1500, text: "alpha beta"),
            Self.sys(id: 100, start: 1500, end: 3000, text: "gamma delta")
        ]
        let pairs = SpeakerBleedDeduper.pairsFromConcatenationPrePass(
            mics: mics, systems: systems
        )
        #expect(pairs.isEmpty)
    }

    @Test func concatenationLongerSystemWinsTieBreak() {
        let mics = [
            Self.mic(id: 1, start: 500, end: 1100, text: "alpha beta"),
            Self.mic(id: 2, start: 1500, end: 2100, text: "gamma delta")
        ]
        let systems = [
            Self.sys(id: 99, start: 0, end: 10000, text: "alpha beta gamma delta"),
            Self.sys(id: 100, start: 0, end: 3000, text: "alpha beta gamma delta")
        ]
        let pairs = SpeakerBleedDeduper.pairsFromConcatenationPrePass(
            mics: mics, systems: systems
        )
        for pair in pairs {
            #expect(pair.againstID == 99, "longest containing system wins")
        }
    }

    @Test func concatenationEqualLengthTieBreakLowestId() {
        let mics = [
            Self.mic(id: 1, start: 500, end: 1100, text: "alpha beta"),
            Self.mic(id: 2, start: 1500, end: 2100, text: "gamma delta")
        ]
        let systems = [
            Self.sys(id: 200, start: 0, end: 5000, text: "alpha beta gamma delta"),
            Self.sys(id: 99, start: 0, end: 5000, text: "alpha beta gamma delta")
        ]
        let pairs = SpeakerBleedDeduper.pairsFromConcatenationPrePass(
            mics: mics, systems: systems
        )
        for pair in pairs {
            #expect(pair.againstID == 99, "lowest id wins on equal-length tie")
        }
    }

    @Test func v2OrchestratorRunsPrePassThenPairwise() throws {
        // Two-fragment mic group inside one long system (pre-pass
        // territory) PLUS a different-speaker mic segment matching a
        // separate system pairwise. Mic 1+2 share speakerID 100;
        // mic 4 uses speakerID 101 so it's NOT grouped with them by
        // `groupConsecutiveSameSpeaker`. Expect 2 concat pairs + 1
        // pairwise pair.
        let fragmentTokens = (1 ... 5).map { "tok\($0)" }.joined(separator: " ")
        let standaloneTokens = (10 ... 30).map { "stand\($0)" }.joined(separator: " ")
        let mics = [
            Self.mic(id: 1, start: 200, end: 900, text: fragmentTokens, speakerID: 100),
            Self.mic(id: 2, start: 1100, end: 1800, text: fragmentTokens, speakerID: 100),
            Self.mic(id: 4, start: 5000, end: 7000, text: standaloneTokens, speakerID: 101)
        ]
        let systems = [
            Self.sys(id: 99, start: 0, end: 3000,
                     text: "\(fragmentTokens) \(fragmentTokens) tail tail tail"),
            Self.sys(id: 100, start: 4500, end: 8000, text: standaloneTokens)
        ]
        let pairs = SpeakerBleedDeduper.pairsToDedup(segments: mics + systems, version: .v2)
        try #require(pairs.count == 3, "expected 2 concat + 1 pairwise; got \(pairs)")
        let concatPairs = pairs.filter { $0.promotionReason == .concatenation }
        let pairwisePairs = pairs.filter { $0.promotionReason == .pairwise }
        #expect(concatPairs.count == 2)
        #expect(pairwisePairs.count == 1)
        #expect(Set(concatPairs.map(\.dedupedID)) == [1, 2])
        #expect(pairwisePairs.first?.dedupedID == 4)
    }
}
