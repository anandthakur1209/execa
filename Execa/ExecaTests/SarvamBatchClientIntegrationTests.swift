@testable import Execa
import Foundation
import Testing

/// Drives the real `SarvamBatchClient` end-to-end against the live
/// Sarvam batch endpoint with `Fixtures/hello.wav`. Permission-gated on
/// a Keychain entry — skipped silently if no key is stored, so a fresh
/// dev machine or CI doesn't hard-fail. Same gating pattern as
/// `SarvamProviderIntegrationTests`.
///
/// What it asserts: the six-step lifecycle round-trips, decoding
/// produces ≥1 segment with non-empty text and a numeric speaker ID.
/// Doesn't assert exact transcript text — Sarvam can transcribe the
/// same audio slightly differently across runs.
///
/// Wall-clock cost: hello.wav is a few seconds long; Sarvam's batch
/// returns in roughly 5–10 s (the probe saw <2 s, but we give margin).
struct SarvamBatchClientIntegrationTests {
    @Test func endToEndDiarizesHelloWav() async throws {
        let keychain = KeychainStore()
        let service = KeychainStore.serviceName(forProvider: "sarvam")
        guard let key = (try? keychain.get(service: service, account: "default")), !key.isEmpty else {
            // Skip on machines without a key — same gating as the
            // streaming integration test.
            return
        }

        let bundle = Bundle(for: BundleAnchor.self)
        guard let wavURL = bundle.url(forResource: "hello", withExtension: "wav") else {
            Issue.record("missing Fixtures/hello.wav in test bundle")
            return
        }

        // Compress the poll cadence so the test resolves quickly. The
        // batch is fast on a 3 s file; 1 s polls are gentle enough for
        // the live API and bound the test wall-clock to ~30 s for the
        // 5 min budget.
        let client = try SarvamBatchClient(
            apiKey: key,
            baseURL: #require(URL(string: "https://api.sarvam.ai")),
            session: .shared,
            pollTimeout: .seconds(180),
            pollInterval: .seconds(1)
        )

        let result = try await client.diarize(wavURL: wavURL, languageCode: "en-IN")
        try #require(!result.segments.isEmpty, "expected at least one diarized segment")
        let first = result.segments[0]
        #expect(!first.text.isEmpty, "first segment should have non-empty text")
        #expect(first.endMs > first.startMs, "end_ms should follow start_ms")
        // Speaker ID conversion already happened at the parser; here
        // we just sanity-check it stayed numeric (any non-negative).
        #expect(first.speakerID >= 0)
    }
}

private final class BundleAnchor {}
