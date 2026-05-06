import Foundation

protocol AudioSource: Sendable {
    func start() async throws
    func stop() async
    var stream: AsyncStream<AudioBuffer> { get async }
}
