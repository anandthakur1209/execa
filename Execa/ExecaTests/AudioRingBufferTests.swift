@testable import Execa
import Foundation
import Testing

struct AudioRingBufferTests {
    private static func chunk(frames: Int, marker: Int16 = 0) -> PCMChunk {
        PCMChunk(
            source: .mic,
            sampleRate: 16000,
            channelCount: 1,
            frameCount: frames,
            captureTime: Date(),
            samples: [Int16](repeating: marker, count: frames)
        )
    }

    @Test func keepsRecent30SecondsAtDefaultCap() async {
        let ring = AudioRingBuffer()
        // Push 35 s @ 16 kHz in 1-s chunks. Default cap is 30 s = 480 000
        // frames. Expect the ring to retain the last 30 chunks.
        for second in 0 ..< 35 {
            await ring.push(Self.chunk(frames: 16000, marker: Int16(second)))
        }
        let buffered = await ring.bufferedFrameCount
        let chunkCount = await ring.bufferedChunkCount
        #expect(buffered == 30 * 16000, "expected 30 s of frames, got \(buffered)")
        #expect(chunkCount == 30, "expected 30 chunks, got \(chunkCount)")
    }

    @Test func drainReturnsInsertionOrderAndClears() async {
        let ring = AudioRingBuffer(maxFrames: 1000)
        await ring.push(Self.chunk(frames: 100, marker: 1))
        await ring.push(Self.chunk(frames: 200, marker: 2))
        await ring.push(Self.chunk(frames: 300, marker: 3))

        let drained = await ring.drain()
        #expect(drained.count == 3)
        #expect(drained[0].samples.first == 1)
        #expect(drained[1].samples.first == 2)
        #expect(drained[2].samples.first == 3)

        let postDrainFrames = await ring.bufferedFrameCount
        #expect(postDrainFrames == 0, "ring should be empty after drain")
    }

    @Test func dropsOldestWhenOverCap() async {
        // Cap of 500 frames; push 4 × 200 = 800 frames worth. The first
        // chunk should be dropped to keep us under cap.
        let ring = AudioRingBuffer(maxFrames: 500)
        await ring.push(Self.chunk(frames: 200, marker: 1))
        await ring.push(Self.chunk(frames: 200, marker: 2))
        await ring.push(Self.chunk(frames: 200, marker: 3))
        await ring.push(Self.chunk(frames: 200, marker: 4))

        let drained = await ring.drain()
        // Expect chunks 3 and 4 retained (=400 frames, last marker dropping
        // chunks 1 and 2). The drop loop drops oldest until totalFrames
        // <= maxFrames.
        #expect(drained.count == 2, "expected 2 chunks retained, got \(drained.count)")
        #expect(drained.first?.samples.first == 3)
        #expect(drained.last?.samples.first == 4)
    }

    @Test func emptyDrainIsHarmless() async {
        let ring = AudioRingBuffer()
        let drained = await ring.drain()
        #expect(drained.isEmpty)
    }
}
