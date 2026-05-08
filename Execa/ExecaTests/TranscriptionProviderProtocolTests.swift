@testable import Execa
import Foundation
import Testing

struct TranscriptionProviderProtocolTests {
    @Test func tokenEquality() {
        let lhs = TranscriptToken(
            startMs: 0,
            endMs: 1500,
            speakerID: 0,
            text: "hello world",
            confidence: 0.95,
            language: "en"
        )
        let rhs = TranscriptToken(
            startMs: 0,
            endMs: 1500,
            speakerID: 0,
            text: "hello world",
            confidence: 0.95,
            language: "en"
        )
        #expect(lhs == rhs)
    }

    @Test func eventEqualityDistinguishesInterimAndFinal() {
        let token = TranscriptToken(
            startMs: 0,
            endMs: 1000,
            speakerID: 0,
            text: "hi",
            confidence: nil,
            language: nil
        )
        // .interim and .final are visually similar but semantically distinct
        // at the decoder layer; their equality must NOT collapse.
        #expect(TranscriptionEvent.interim(token) != TranscriptionEvent.final(token))
        #expect(TranscriptionEvent.interim(token) == TranscriptionEvent.interim(token))
    }

    @Test func errorEqualityDistinguishesCases() {
        #expect(TranscriptionError.authFailed != .reconnectExhausted)
        #expect(TranscriptionError.other("a") != .other("b"))
        #expect(TranscriptionError.other("same") == .other("same"))
    }

    // The Decodable / wire-format gates (real Sarvam interim + final fixture
    // JSON → TranscriptionEvent) land in commit 4 when the discovery probe
    // captures the actual event shape. No spec-derived Decodable tests
    // here — the spec example is illustrative and we don't want to bake
    // a stale shape into tests.
}
