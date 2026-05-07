import AVFAudio
import Foundation

enum AudioResamplerError: Error {
    case converterCreationFailed
    case conversionFailed(Error?)
}

struct AudioResampler {
    static let sttSampleRate: Double = 16000

    static func sttFormat() throws -> AVAudioFormat {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sttSampleRate,
            channels: 1,
            interleaved: true
        ) else {
            throw AudioResamplerError.converterCreationFailed
        }
        return format
    }

    let inputFormat: AVAudioFormat
    let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter

    init(inputFormat: AVAudioFormat, outputFormat: AVAudioFormat? = nil) throws {
        self.inputFormat = inputFormat
        self.outputFormat = try outputFormat ?? Self.sttFormat()
        guard let converter = AVAudioConverter(from: inputFormat, to: self.outputFormat) else {
            throw AudioResamplerError.converterCreationFailed
        }
        self.converter = converter
    }

    func convert(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(input.frameLength) * ratio + 1)
        guard let output = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: outputCapacity
        ) else {
            throw AudioResamplerError.conversionFailed(nil)
        }

        var consumed = false
        var convError: NSError?
        // Signal `.noDataNow` (not `.endOfStream`) when we've handed the
        // converter our single input buffer. `.endOfStream` permanently
        // closes the converter's input stream, causing every subsequent
        // `convert(to:)` call on the same instance to return zero frames.
        // For a streaming pipeline that calls `convert(_:)` repeatedly with
        // successive buffers, we need the converter to stay open and just
        // wait for the next call.
        let status = converter.convert(to: output, error: &convError) { _, statusOut in
            if consumed {
                statusOut.pointee = .noDataNow
                return nil
            }
            consumed = true
            statusOut.pointee = .haveData
            return input
        }

        if status == .error {
            throw AudioResamplerError.conversionFailed(convError)
        }
        return output
    }
}
