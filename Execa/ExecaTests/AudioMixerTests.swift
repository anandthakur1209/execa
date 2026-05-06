import AVFAudio
@testable import Execa
import Foundation
import Testing

struct AudioMixerTests {
    private static let sampleRate: Double = 48000

    private static func writeWAV(_ samples: [Int16], to url: URL) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: true
        ) else {
            throw NSError(domain: "AudioMixerTests", code: 1)
        }
        let writer = try AudioFileWriter(url: url, format: format)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw NSError(domain: "AudioMixerTests", code: 2)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let pointer = buffer.int16ChannelData {
            for index in 0 ..< samples.count {
                pointer[0][index] = samples[index]
            }
        }
        try writer.write(buffer)
        writer.close()
    }

    private static func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("execa-mixer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func mixesNormalCase() throws {
        let dir = try Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let oneSecond = Int(Self.sampleRate)
        let silence = [Int16](repeating: 0, count: oneSecond)
        var sine = [Int16]()
        sine.reserveCapacity(oneSecond)
        let amplitude: Double = 16000
        for index in 0 ..< oneSecond {
            let phase = Double(index) / Self.sampleRate * 2 * .pi * 440
            sine.append(Int16(amplitude * sin(phase)))
        }

        let micURL = dir.appendingPathComponent("mic.wav")
        let systemURL = dir.appendingPathComponent("system.wav")
        let masterURL = dir.appendingPathComponent("master.flac")
        try Self.writeWAV(silence, to: micURL)
        try Self.writeWAV(sine, to: systemURL)

        try AudioMixer.writeMasterFLAC(micWAV: micURL, systemWAV: systemURL, output: masterURL)
        let master = try AVAudioFile(forReading: masterURL)
        #expect(master.length == AVAudioFramePosition(oneSecond))
        #expect(master.fileFormat.channelCount == 1)
        #expect(master.fileFormat.sampleRate == Self.sampleRate)
    }

    @Test func emptyInputsProduceValidFLAC() throws {
        let dir = try Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let micURL = dir.appendingPathComponent("mic.wav")
        let systemURL = dir.appendingPathComponent("system.wav")
        let masterURL = dir.appendingPathComponent("master.flac")
        try Self.writeWAV([], to: micURL)
        try Self.writeWAV([], to: systemURL)

        try AudioMixer.writeMasterFLAC(micWAV: micURL, systemWAV: systemURL, output: masterURL)
        let master = try AVAudioFile(forReading: masterURL)
        #expect(master.length >= 1, "expected at least one silent frame for an empty mix")
    }

    @Test func mismatchedLengthsPadShorterWithSilence() throws {
        let dir = try Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let oneSecond = Int(Self.sampleRate)
        let threeSeconds = oneSecond * 3
        let micURL = dir.appendingPathComponent("mic.wav")
        let systemURL = dir.appendingPathComponent("system.wav")
        let masterURL = dir.appendingPathComponent("master.flac")
        try Self.writeWAV([Int16](repeating: 0, count: oneSecond), to: micURL)
        try Self.writeWAV([Int16](repeating: 0, count: threeSeconds), to: systemURL)

        try AudioMixer.writeMasterFLAC(micWAV: micURL, systemWAV: systemURL, output: masterURL)
        let master = try AVAudioFile(forReading: masterURL)
        #expect(master.length == AVAudioFramePosition(threeSeconds))
    }
}
