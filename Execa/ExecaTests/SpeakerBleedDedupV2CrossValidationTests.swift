@testable import Execa
import Foundation
import Testing

/// Phase 3.5b commit (d) tests for `SpeakerBleedDeduper`'s
/// cross-validation post-pass. Promotes the remaining unflagged
/// segments of any mic speaker who's already ≥ 80% flagged (≥ 3
/// segments) by pairwise + concatenation. Catches "whole mic
/// speaker is just bleed echo of system audio."
struct SpeakerBleedDedupV2CrossValidationTests {
    private static func mic(
        id: Int64,
        speakerID: Int64,
        start: Int,
        end: Int,
        text: String,
        confidence: Double? = nil
    ) -> SpeakerBleedDeduper.Segment {
        .init(id: id, speakerID: speakerID, source: "mic",
              startMs: start, endMs: end, text: text, confidence: confidence)
    }

    private static func sys(
        id: Int64,
        speakerID: Int64 = 200,
        start: Int,
        end: Int,
        text: String,
        confidence: Double? = nil
    ) -> SpeakerBleedDeduper.Segment {
        .init(id: id, speakerID: speakerID, source: "system",
              startMs: start, endMs: end, text: text, confidence: confidence)
    }

    @Test func crossValidationPromotesFourOfFive() throws {
        // 5-segment mic speaker; pairwise flags 4 of them (each
        // matches a different system segment one-to-one). The 5th
        // should be promoted to a flag against the system speaker
        // most frequently named in the 4 flagged pairs.
        let sharedTokens = (1 ... 10).map { "tok\($0)" }.joined(separator: " ")
        let mics = (1 ... 5).map { idx -> SpeakerBleedDeduper.Segment in
            // First four mic segments contain the shared tokens so
            // pairwise flags them; the fifth has unrelated text so
            // pairwise does NOT flag.
            let text = idx <= 4 ? sharedTokens : "lorem ipsum dolor sit amet consectetur"
            return Self.mic(
                id: Int64(idx),
                speakerID: 100,
                start: (idx - 1) * 2000,
                end: (idx - 1) * 2000 + 1500,
                text: text
            )
        }
        // Single system speaker covering all four overlapping
        // windows so each pairwise mic finds the same target.
        let systems = (1 ... 4).map { idx -> SpeakerBleedDeduper.Segment in
            Self.sys(
                id: Int64(100 + idx),
                start: (idx - 1) * 2000,
                end: (idx - 1) * 2000 + 1500,
                text: sharedTokens
            )
        }
        let pairs = SpeakerBleedDeduper.pairsToDedup(segments: mics + systems, version: .v2)
        // 4 pairwise + 1 speakerPromotion = 5 total.
        try #require(pairs.count == 5, "got \(pairs.count): \(pairs)")
        let promoted = pairs.filter { $0.promotionReason == .speakerPromotion }
        #expect(promoted.count == 1)
        #expect(promoted.first?.dedupedID == 5, "5th mic segment should be promoted")
        #expect(promoted.first?.containment == nil)
        #expect(promoted.first?.jaccard == nil)
    }

    @Test func crossValidationDoesNotPromoteTwoOfFive() {
        // 5-segment mic speaker, only 2 flagged → ratio 0.4 < 0.8.
        // No promotion.
        let sharedTokens = (1 ... 10).map { "tok\($0)" }.joined(separator: " ")
        let mics = (1 ... 5).map { idx -> SpeakerBleedDeduper.Segment in
            let text = idx <= 2 ? sharedTokens : "unrelated text \(idx)"
            return Self.mic(
                id: Int64(idx), speakerID: 100,
                start: (idx - 1) * 2000, end: (idx - 1) * 2000 + 1500, text: text
            )
        }
        let systems = (1 ... 2).map { idx in
            Self.sys(id: Int64(100 + idx),
                     start: (idx - 1) * 2000, end: (idx - 1) * 2000 + 1500,
                     text: sharedTokens)
        }
        let pairs = SpeakerBleedDeduper.pairsToDedup(segments: mics + systems, version: .v2)
        let promoted = pairs.filter { $0.promotionReason == .speakerPromotion }
        #expect(promoted.isEmpty, "ratio 0.4 is below 0.8; should not promote")
    }

    @Test func crossValidationDoesNotPromoteThreeOfFour() {
        // 4-segment mic, 3 flagged → ratio 0.75 < 0.8. Boundary
        // check (strict < the ratio threshold).
        let sharedTokens = (1 ... 10).map { "tok\($0)" }.joined(separator: " ")
        let mics = (1 ... 4).map { idx -> SpeakerBleedDeduper.Segment in
            let text = idx <= 3 ? sharedTokens : "unrelated text"
            return Self.mic(
                id: Int64(idx), speakerID: 100,
                start: (idx - 1) * 2000, end: (idx - 1) * 2000 + 1500, text: text
            )
        }
        let systems = (1 ... 3).map { idx in
            Self.sys(id: Int64(100 + idx),
                     start: (idx - 1) * 2000, end: (idx - 1) * 2000 + 1500,
                     text: sharedTokens)
        }
        let pairs = SpeakerBleedDeduper.pairsToDedup(segments: mics + systems, version: .v2)
        let promoted = pairs.filter { $0.promotionReason == .speakerPromotion }
        #expect(promoted.isEmpty, "ratio 0.75 must NOT promote (≥ 0.8 required)")
    }

    @Test func crossValidationDoesNotPromoteBelowMinFlagged() {
        // 2-segment mic with 2 flagged → ratio 1.0 but minFlagged=3
        // blocks. No promotion.
        let sharedTokens = (1 ... 10).map { "tok\($0)" }.joined(separator: " ")
        let mics = (1 ... 2).map { idx -> SpeakerBleedDeduper.Segment in
            Self.mic(
                id: Int64(idx), speakerID: 100,
                start: (idx - 1) * 2000, end: (idx - 1) * 2000 + 1500,
                text: sharedTokens
            )
        }
        // Two distinct system speakers so pairwise sees one match
        // each — both mic segments flag.
        let systems = [
            Self.sys(id: 101, speakerID: 200, start: 0, end: 1500, text: sharedTokens),
            Self.sys(id: 102, speakerID: 201, start: 2000, end: 3500, text: sharedTokens)
        ]
        let pairs = SpeakerBleedDeduper.pairsToDedup(segments: mics + systems, version: .v2)
        let promoted = pairs.filter { $0.promotionReason == .speakerPromotion }
        #expect(promoted.isEmpty, "minFlagged=3 floor should block 2-segment speakers")
    }

    @Test func crossValidationPromotedSegmentNearestNeighborAudit() throws {
        // 5-segment mic (4 flagged pairwise, 1 unflagged) → ratio
        // 0.8, ≥ 3 flagged → promotion fires. The promoted segment's
        // audit FK should be the nearest-neighbor system segment by
        // `startMs` within the target system speaker.
        let sharedTokens = (1 ... 10).map { "tok\($0)" }.joined(separator: " ")
        let mics: [SpeakerBleedDeduper.Segment] = [
            Self.mic(id: 1, speakerID: 100, start: 0, end: 1500, text: sharedTokens),
            Self.mic(id: 2, speakerID: 100, start: 2000, end: 3500, text: sharedTokens),
            Self.mic(id: 3, speakerID: 100, start: 4000, end: 5500, text: sharedTokens),
            Self.mic(id: 4, speakerID: 100, start: 6000, end: 7500, text: sharedTokens),
            // Unflagged (no text match against the target speaker's
            // segments): startMs 20000. Nearest system in the target
            // speaker's segments by `startMs` should win the audit.
            Self.mic(id: 5, speakerID: 100, start: 20000, end: 21000,
                     text: "unrelated content here words")
        ]
        let systems = [
            Self.sys(id: 101, start: 0, end: 1500, text: sharedTokens),
            Self.sys(id: 102, start: 2000, end: 3500, text: sharedTokens),
            Self.sys(id: 103, start: 4000, end: 5500, text: sharedTokens),
            Self.sys(id: 104, start: 6000, end: 7500, text: sharedTokens),
            // Far system in the same target speaker. mic 5 (start
            // 20000) is closest to this one (start 19000) by
            // distance 1000.
            Self.sys(id: 105, start: 19000, end: 22000, text: sharedTokens)
        ]
        let pairs = SpeakerBleedDeduper.pairsToDedup(segments: mics + systems, version: .v2)
        let promoted = pairs.filter { $0.promotionReason == .speakerPromotion }
        try #require(promoted.count == 1, "expected promotion; got \(pairs)")
        #expect(promoted.first?.dedupedID == 5)
        #expect(promoted.first?.againstID == 105,
                "nearest-neighbor system segment should win the audit FK")
    }

    @Test func crossValidationTieBreakByLowestSystemID() throws {
        // Two system speakers each match exactly 2 of the mic's 4
        // flagged pairwise pairs (containments all equal, so
        // count + cumulative-containment ties). Lowest system_id
        // wins per the deterministic tie-break.
        let sharedTokens = (1 ... 10).map { "tok\($0)" }.joined(separator: " ")
        let mics = (1 ... 5).map { idx -> SpeakerBleedDeduper.Segment in
            let text = idx <= 4 ? sharedTokens : "different unrelated text content"
            return Self.mic(
                id: Int64(idx), speakerID: 100,
                start: (idx - 1) * 3000, end: (idx - 1) * 3000 + 1500, text: text
            )
        }
        // Two distinct system speakers, each owning two segments.
        // mic 1+2 match systems with speakerID 200; mic 3+4 match
        // speakerID 201.
        let systems = [
            Self.sys(id: 99, speakerID: 200, start: 0, end: 1500, text: sharedTokens),
            Self.sys(id: 100, speakerID: 200, start: 3000, end: 4500, text: sharedTokens),
            Self.sys(id: 50, speakerID: 201, start: 6000, end: 7500, text: sharedTokens),
            Self.sys(id: 51, speakerID: 201, start: 9000, end: 10500, text: sharedTokens)
        ]
        let pairs = SpeakerBleedDeduper.pairsToDedup(segments: mics + systems, version: .v2)
        let promoted = pairs.filter { $0.promotionReason == .speakerPromotion }
        try #require(promoted.count == 1)
        // Two systems with same flag count + same cumulative
        // containment. Lowest speakerID is 200 (vs 201). Within
        // system speaker 200, segments 99 and 100; mic 5 at 12000
        // is nearer to segment 100 (start 3000, distance 9000) vs
        // 99 (start 0, distance 12000). So audit FK = 100.
        #expect(promoted.first?.againstID == 100,
                "speaker 200 wins by lowest-id; nearest neighbor within = system 100")
    }
}
