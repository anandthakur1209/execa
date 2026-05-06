import AVFAudio
@testable import Execa
import Foundation
import Testing

struct AudioFileWriterTests {
    @Test func writeAndReadBackOneSecondSine() throws {
        let sampleRate: Double = 48000
        let frameCount = AVAudioFrameCount(sampleRate)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: true
        ) else {
            Issue.record("could not create input format")
            return
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            Issue.record("could not create input buffer")
            return
        }
        buffer.frameLength = frameCount
        if let channelData = buffer.int16ChannelData {
            let pointer = channelData[0]
            let amplitude: Double = 16000
            for index in 0 ..< Int(frameCount) {
                let phase = Double(index) / sampleRate * 2 * .pi * 440
                pointer[index] = Int16(amplitude * sin(phase))
            }
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("execa-writer-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try AudioFileWriter(url: url, format: format)
        try writer.write(buffer)
        writer.close()

        let readBack = try AVAudioFile(forReading: url)
        #expect(readBack.length == AVAudioFramePosition(frameCount))
        #expect(readBack.fileFormat.sampleRate == sampleRate)
        #expect(readBack.fileFormat.channelCount == 1)
    }

    @Test func diskFullMappingHandlesPosixAndCocoa() {
        let posix = NSError(domain: NSPOSIXErrorDomain, code: 28, userInfo: nil)
        #expect(AudioFileWriterError.mapping(posix) == .diskFull)

        let cocoa = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError, userInfo: nil)
        #expect(AudioFileWriterError.mapping(cocoa) == .diskFull)

        let unrelated = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError, userInfo: nil)
        if case .diskFull = AudioFileWriterError.mapping(unrelated) {
            Issue.record("unrelated Cocoa error should not map to diskFull")
        }
    }
}
