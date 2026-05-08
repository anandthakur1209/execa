import Foundation

/// 30-second ring buffer in front of each `SarvamProvider`'s WebSocket. The
/// provider's producer task pushes every `PCMChunk` into the ring AND into
/// the live socket; on a reconnect the ring is drained into the new socket
/// before live audio resumes, so we don't lose what we said during the
/// outage. Per spec §4.2.
///
/// **Sized by frame count, not chunk count** — variable-sized chunks from
/// upstream don't change the buffer's wall-clock duration. With Sarvam's
/// expected 16 kHz Int16 mono format, the cap defaults to 30 s × 16 000 = 480 000
/// frames per source (~960 KB).
///
/// Design note: this is a discard-oldest ring, not a bounded queue. We
/// preserve the most recent 30 s; older chunks are dropped silently when
/// new ones arrive. The provider never blocks on push.
actor AudioRingBuffer {
    private var chunks: [PCMChunk] = []
    private var totalFrames: Int = 0
    private let maxFrames: Int

    /// - Parameter maxFrames: max frames retained across all chunks. The
    ///   default of 480 000 corresponds to 30 s at 16 kHz.
    init(maxFrames: Int = 480_000) {
        self.maxFrames = maxFrames
    }

    /// O(1) amortized: append, then drop oldest until under cap. The drop
    /// loop runs at most a handful of iterations per push because chunk
    /// sizes are bounded.
    func push(_ chunk: PCMChunk) {
        chunks.append(chunk)
        totalFrames += chunk.frameCount
        while totalFrames > maxFrames, !chunks.isEmpty {
            let removed = chunks.removeFirst()
            totalFrames -= removed.frameCount
        }
    }

    /// Returns all retained chunks in insertion order, then clears the
    /// buffer. Called by `SarvamProvider`'s reconnect supervisor right
    /// after a successful reconnect, before live audio resumes.
    func drain() -> [PCMChunk] {
        let drained = chunks
        chunks = []
        totalFrames = 0
        return drained
    }

    /// For tests + diagnostics.
    var bufferedFrameCount: Int {
        totalFrames
    }

    var bufferedChunkCount: Int {
        chunks.count
    }
}
