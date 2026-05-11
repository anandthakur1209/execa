import Foundation

/// Selects which dedup algorithm runs. Phase 3.5 shipped v1 (Jaccard
/// 0.6); Phase 3.5b ships v2 (containment 0.75 + Porter-light stemming
/// + concatenation pre-pass + cross-validation post-pass). v1 is
/// retained as a flag-fallback for A/B regression if v2 over-dedupes
/// in real meetings.
enum BleedDedupAlgorithmVersion: String, Equatable {
    case v1
    case v2
}

/// Why a segment was flagged as bleed. Carried in `DedupPair` for
/// in-memory audit only; the DB persists just the
/// `deduped_against_segment_id` FK. Lets the manual-smoke story
/// explain which v2 pass flagged each segment when debugging.
enum PromotionReason: Equatable {
    /// Pairwise pass (v1 or v2) — single mic segment matched against
    /// a single system segment.
    case pairwise
    /// V2 concatenation pre-pass — multiple consecutive same-speaker
    /// mic segments compared as one joined string against one
    /// containing system segment.
    case concatenation
    /// V2 cross-validation post-pass — speaker-level promotion that
    /// fires when ≥80% of a mic speaker's segments (and ≥3 in
    /// absolute count) were already flagged by the pairwise /
    /// concatenation passes.
    case speakerPromotion
}

/// One flag in a dedup pass: a mic-side segment soft-deleted against
/// a surviving system-side segment, with audit metadata.
/// `containment` and `jaccard` are nil when the score isn't
/// applicable to this flag's reason (e.g. speaker-promotion pairs
/// don't go through pairwise scoring).
struct DedupPair: Equatable {
    let dedupedID: Int64
    let againstID: Int64
    let containment: Double?
    let jaccard: Double?
    let promotionReason: PromotionReason
}

/// Result of one dedup pass. `pairs` is the primary field carrying
/// audit metadata for each soft-delete; `dedupedPairs` is a computed
/// `[(Int64, Int64)]` projection for backward compat with callers
/// that only need the ID pairs.
struct DedupResult: Equatable {
    let pairs: [DedupPair]

    var dedupedPairs: [(Int64, Int64)] {
        pairs.map { ($0.dedupedID, $0.againstID) }
    }
}
