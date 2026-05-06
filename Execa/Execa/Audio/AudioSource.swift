import Foundation

protocol AudioSource: Sendable {
    func start(archivalURL: URL) async throws
    func stop() async
    var sttStream: AsyncStream<AudioBuffer> { get }
}
