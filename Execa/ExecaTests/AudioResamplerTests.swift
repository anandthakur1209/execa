import AVFAudio
@testable import Execa
import Foundation
import Testing

struct AudioResamplerTests {
    @Test func downsample48kStereoTo16kMono() throws {
        let inputRate: Double = 48000
        let outputRate: Double = 16000
        let inputFrameCount = AVAudioFrameCount(inputRate)

        guard let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputRate,
            channels: 2,
            interleaved: false
        ) else {
            Issue.record("could not create input format")
            return
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: inputFrameCount) else {
            Issue.record("could not create input buffer")
            return
        }
        buffer.frameLength = inputFrameCount
        if let channelData = buffer.floatChannelData {
            for channel in 0 ..< 2 {
                let pointer = channelData[channel]
                for frame in 0 ..< Int(inputFrameCount) {
                    let phase = Double(frame) / inputRate * 2 * .pi * 440
                    pointer[frame] = Float(sin(phase) * 0.5)
                }
            }
        }

        let resampler = try AudioResampler(inputFormat: inputFormat)
        let output = try resampler.convert(buffer)
        #expect(output.format.sampleRate == outputRate)
        #expect(output.format.channelCount == 1)
        #expect(output.format.commonFormat == .pcmFormatInt16)

        // AudioResampler is built for streaming use: it signals `.noDataNow`
        // (not `.endOfStream`) when handed each input buffer, so the
        // underlying AVAudioConverter holds ~50–100 ms of trailing frames
        // internally to feed its filter taps on the next call. In a meeting,
        // those frames flow out via the subsequent buffer; only the last
        // <100 ms of the final input buffer is unrecoverable. This test feeds
        // a single 1 s input buffer, so we tolerate up to ~100 ms (1600
        // frames @ 16 kHz) of trailing-side drift.
        let expectedFrames = Int(Double(inputFrameCount) * outputRate / inputRate)
        let actualFrames = Int(output.frameLength)
        let delta = abs(actualFrames - expectedFrames)
        #expect(delta <= 1600, "frame count drift \(delta) too large for 1-second sine")
    }
}
