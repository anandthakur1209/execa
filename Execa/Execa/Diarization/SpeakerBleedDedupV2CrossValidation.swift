import Foundation

/// Phase 3.5b cross-validation post-pass + Phase 3.5c merge-aware
/// target-speaker selection. Lives in its own file so the v2
/// algorithm body (`SpeakerBleedDedupV2.swift`) stays under the
/// file-length cap and the post-pass surface area is grouped here.
extension SpeakerBleedDeduper {
    /// Speaker-level promotion: for each mic speaker, if ≥
    /// `crossValidationFlagRatio` of their segments are already
    /// flagged AND ≥ `crossValidationMinFlagged` in absolute count,
    /// promote the speaker's remaining unflagged segments. The target
    /// EFFECTIVE system speaker is the most-frequent across the
    /// existing flagged pairs (count → cumulative containment →
    /// lowest id). Phase 3.5c: grouping uses effective speakers so
    /// matches that previously scattered across over-segmented Sarvam
    /// output consolidate after manual merge.
    static func applySpeakerLevelPromotion(
        pairs: [DedupPair],
        mics: [Segment],
        systems: [Segment]
    ) -> [DedupPair] {
        guard !pairs.isEmpty, !mics.isEmpty, !systems.isEmpty else { return [] }
        let micsBySpeaker = Dictionary(grouping: mics, by: \.speakerID)
        let systemEffectiveByID = Dictionary(
            uniqueKeysWithValues: systems.map { ($0.id, $0.effectiveSpeakerID) }
        )
        let flaggedSegmentIDs = Set(pairs.map(\.dedupedID))
        let pairsByMicSegment = Dictionary(
            uniqueKeysWithValues: pairs.map { ($0.dedupedID, $0) }
        )
        var promoted: [DedupPair] = []
        for (_, segments) in micsBySpeaker {
            let total = segments.count
            let flaggedSegments = segments.filter { flaggedSegmentIDs.contains($0.id) }
            let flaggedCount = flaggedSegments.count
            guard flaggedCount >= crossValidationMinFlagged else { continue }
            let ratio = Double(flaggedCount) / Double(total)
            guard ratio >= crossValidationFlagRatio else { continue }
            guard let targetEffectiveID = chooseTargetSystemSpeaker(
                flaggedSegments: flaggedSegments,
                pairsByMicSegment: pairsByMicSegment,
                systemEffectiveByID: systemEffectiveByID
            ) else { continue }
            let targetSegments = systems
                .filter { $0.effectiveSpeakerID == targetEffectiveID }
                .sorted { $0.startMs < $1.startMs }
            guard !targetSegments.isEmpty else { continue }
            for segment in segments where !flaggedSegmentIDs.contains(segment.id) {
                guard let neighborSystem = nearestNeighborSystem(
                    micStart: segment.startMs,
                    targetSystems: targetSegments
                ) else { continue }
                promoted.append(DedupPair(
                    dedupedID: segment.id,
                    againstID: neighborSystem.id,
                    containment: nil,
                    jaccard: nil,
                    promotionReason: .speakerPromotion
                ))
            }
        }
        return promoted
    }

    /// Picks the EFFECTIVE system speaker most frequently named as
    /// "against" in the flagged mic segments. Tie-break order:
    ///   1. Highest count (most-frequent effective speaker wins).
    ///   2. Tie → highest cumulative containment across those flagged
    ///      pairs.
    ///   3. Still tied → lowest effective `speakers.id`.
    private static func chooseTargetSystemSpeaker(
        flaggedSegments: [Segment],
        pairsByMicSegment: [Int64: DedupPair],
        systemEffectiveByID: [Int64: Int64]
    ) -> Int64? {
        var countByEffective: [Int64: Int] = [:]
        var containmentSumByEffective: [Int64: Double] = [:]
        for segment in flaggedSegments {
            guard let pair = pairsByMicSegment[segment.id] else { continue }
            guard let effective = systemEffectiveByID[pair.againstID] else { continue }
            countByEffective[effective, default: 0] += 1
            containmentSumByEffective[effective, default: 0] += pair.containment ?? 0
        }
        return countByEffective
            .max { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value < rhs.value }
                let lhsSum = containmentSumByEffective[lhs.key] ?? 0
                let rhsSum = containmentSumByEffective[rhs.key] ?? 0
                if lhsSum != rhsSum { return lhsSum < rhsSum }
                return lhs.key > rhs.key // invert: lowest id wins
            }?
            .key
    }

    /// For a promoted (unflagged) mic segment, pick the
    /// nearest-neighbor system segment by `startMs` to populate the
    /// audit FK. Best-effort: speaker-level promotion already
    /// decided this whole mic speaker is bleed; the FK is just an
    /// audit pointer.
    private static func nearestNeighborSystem(
        micStart: Int,
        targetSystems: [Segment]
    ) -> Segment? {
        guard !targetSystems.isEmpty else { return nil }
        return targetSystems.min { lhs, rhs in
            abs(lhs.startMs - micStart) < abs(rhs.startMs - micStart)
        }
    }
}
