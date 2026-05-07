import Foundation

protocol AudioSource: Sendable {
    func start(archivalURL: URL) async throws
    func stop() async
    var sttStream: AsyncStream<PCMChunk> { get }
    /// Errors that arise mid-recording (disk full, write failures, etc.) flow
    /// out via this stream so AudioCaptureService can react without blocking
    /// the audio tap thread.
    var errorStream: AsyncStream<MeetingError> { get }
}
