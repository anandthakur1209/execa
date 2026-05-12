import Foundation

/// Phase 3.5b v2 scoring primitives + Porter-light stemmer. Lives in
/// its own file so the v2 algorithm body (`SpeakerBleedDedupV2.swift`)
/// stays under the file-length cap; these are NLP utilities, not
/// dedup-algorithm-control-flow, and the split is cleaner than
/// inlining.
extension SpeakerBleedDeduper {
    /// Containment coefficient: `|mic_tokens ∩ system_tokens| /
    /// |mic_tokens|`, computed over STEMMED tokens. Returns 0 if the
    /// mic side tokenizes to empty (defensive — divide-by-zero would
    /// otherwise NaN). Asymmetric by design: "what fraction of the
    /// mic's vocabulary appears in the system's vocabulary." A mic
    /// fragment of a larger system utterance hits 1.0; a paraphrase
    /// with different word choice stays low.
    static func containmentTextSimilarity(mic: String, system: String) -> Double {
        let micTokens = Set(tokenList(mic))
        let systemTokens = Set(tokenList(system))
        guard !micTokens.isEmpty else { return 0 }
        let intersectionCount = micTokens.intersection(systemTokens).count
        return Double(intersectionCount) / Double(micTokens.count)
    }

    /// Ordered list of stemmed tokens. v2 uses this instead of the
    /// `Set<String>`-returning `tokenize(_:)` because the concatenation
    /// pre-pass needs to preserve order before joining; containment
    /// scoring builds sets at the call site. Stemming is ASCII-only —
    /// see `stem(_:)`.
    static func tokenList(_ text: String) -> [String] {
        let lower = text.lowercased()
        let separators = CharacterSet.alphanumerics.inverted
        return lower
            .components(separatedBy: separators)
            .filter { !$0.isEmpty }
            .map { stem($0) }
    }

    /// Porter-light suffix stripper, ASCII-only. Six rules applied in
    /// precedence order; first match wins and the rule returns. Each
    /// rule has a minimum-input-length guard so common short words
    /// (`his`, `was`, `yes`, `ring`, `fed`, `bed`, `uses`) don't get
    /// catastrophically over-stemmed. Devanagari and other non-ASCII
    /// tokens pass through untouched — the gate is
    /// `String.allSatisfy(\.isASCII)`.
    ///
    /// Rules (input-length guards; result lengths follow trivially):
    ///   1. "ies" → "y"  (input ≥ 5): "companies" → "company"
    ///   2. "ied" → "y"  (input ≥ 5): "tried" → "try"
    ///   3. "ing" → ""   (input ≥ 7): "training" → "train"; "ring" stays
    ///   4. "ed"  → ""   (input ≥ 6): "trained" → "train"; "fed", "bed" stay
    ///   5. "es"  → ""   (input ≥ 5): "boxes" → "box"
    ///   6. "s"   → ""   (input ≥ 5): "scripts" → "script"; "his", "was", "uses" stay
    static func stem(_ token: String) -> String {
        guard token.allSatisfy(\.isASCII) else { return token }
        let chars = Array(token)
        let count = chars.count

        if count >= 5, chars.suffix(3) == ["i", "e", "s"] {
            return String(chars.dropLast(3)) + "y"
        }
        if count >= 5, chars.suffix(3) == ["i", "e", "d"] {
            return String(chars.dropLast(3)) + "y"
        }
        if count >= 7, chars.suffix(3) == ["i", "n", "g"] {
            return String(chars.dropLast(3))
        }
        if count >= 6, chars.suffix(2) == ["e", "d"] {
            return String(chars.dropLast(2))
        }
        if count >= 5, chars.suffix(2) == ["e", "s"] {
            return String(chars.dropLast(2))
        }
        if count >= 5, chars.last == "s" {
            return String(chars.dropLast(1))
        }
        return token
    }
}
