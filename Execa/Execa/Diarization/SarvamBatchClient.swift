import Foundation

/// Sarvam batch Speech-to-Text client. Uploads a finalized WAV file to
/// the batch endpoint with `with_diarization=true` and returns parsed
/// per-segment speaker IDs + text + timestamps.
///
/// Wire format — endpoint URL, auth scheme, multipart shape, response
/// JSON — is captured by the commit-2 discovery probe
/// (`scripts/sarvam-batch-probe.swift`). Real implementation lands in
/// commit 3. This commit ships an empty actor so the rest of Phase 3's
/// plumbing (`DiarizationService` constructor, tests with
/// `MockSarvamBatchClient`) compiles against a stable type.
///
/// Why a protocol-less concrete actor for now: tests will use a separate
/// mock type (`MockSarvamBatchClient`) injected via a closure factory in
/// `DiarizationService.init`; we don't need a `SarvamBatchClientProtocol`
/// to make that work. If a third batch provider ever lands (Phase 6+),
/// extract a protocol then.
actor SarvamBatchClient {
    private let apiKey: String

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    /// Uploads `wavURL` to the Sarvam batch endpoint and returns the
    /// diarized result. Stub for now — real implementation lands in
    /// commit 3 after the discovery probe captures the wire format.
    func diarize(wavURL _: URL, languageCode _: String) async throws -> SarvamBatchResult {
        throw SarvamBatchClientError.notYetImplemented
    }
}

enum SarvamBatchClientError: Error, Equatable {
    case notYetImplemented
    case invalidURL
    case uploadFailed(statusCode: Int, message: String)
    case decodingFailed(String)
}
