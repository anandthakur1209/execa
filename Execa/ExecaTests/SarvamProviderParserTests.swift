@testable import Execa
import Foundation
import Testing

struct SarvamProviderParserTests {
    /// Round-trips the captured-from-wire fixture through
    /// `SarvamProvider.parseMessage(_:)`. Verifies that:
    /// - the envelope `type: "data"` maps to a `.final` event;
    /// - the transcript text round-trips intact;
    /// - the provider derives `endMs` from `metrics.audio_duration` (since
    ///   Sarvam streaming doesn't emit per-token timestamps);
    /// - `speakerID` is hardcoded to 0 (Sarvam streaming = no diarization,
    ///   per Path B).
    @Test func parsesRealSarvamDataMessage() throws {
        let bundle = Bundle(for: BundleAnchor.self)
        let url = try #require(bundle.url(forResource: "sarvam-data-sample", withExtension: "json"))
        let text = try String(contentsOf: url, encoding: .utf8)
        let event = SarvamProvider.parseMessage(text)
        guard case let .final(token) = event else {
            Issue.record("expected .final, got \(String(describing: event))")
            return
        }
        #expect(token.text == "Hello. This is a phase two transcription test.")
        #expect(token.speakerID == 0)
        #expect(token.language == "en-IN")
        // metrics.audio_duration was 3.84 → end_ms = 3840.
        #expect(token.endMs == 3840)
        #expect(token.startMs == 0)
    }

    @Test func ignoresUnknownEnvelopeType() {
        let unknown = #"{"type":"speech_start","data":null}"#
        #expect(SarvamProvider.parseMessage(unknown) == nil)
    }

    @Test func ignoresMalformedJSON() {
        #expect(SarvamProvider.parseMessage("not json") == nil)
        #expect(SarvamProvider.parseMessage("") == nil)
    }
}

/// Bundle anchor: `Bundle(for: BundleAnchor.self)` resolves the test
/// target's resource bundle, where `Fixtures/*.json` live. The class
/// itself has no behavior.
private final class BundleAnchor {}
