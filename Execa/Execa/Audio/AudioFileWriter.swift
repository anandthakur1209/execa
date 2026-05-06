import AVFAudio
import Foundation

enum AudioFileWriterError: Error, Equatable {
    case diskFull
    case underlying(NSError)

    static func mapping(_ error: Error) -> AudioFileWriterError {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileWriteOutOfSpaceError {
            return .diskFull
        }
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == 28 {
            return .diskFull
        }
        return .underlying(nsError)
    }
}

actor AudioFileWriter {
    private var file: AVAudioFile?
    private let url: URL
    private let format: AVAudioFormat

    init(url: URL, format: AVAudioFormat) throws {
        self.url = url
        self.format = format
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount),
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        do {
            file = try AVAudioFile(
                forWriting: url,
                settings: settings,
                commonFormat: .pcmFormatInt16,
                interleaved: true
            )
        } catch {
            throw AudioFileWriterError.mapping(error)
        }
    }

    func write(_ buffer: AVAudioPCMBuffer) throws {
        guard let file else { return }
        do {
            try file.write(from: buffer)
        } catch {
            throw AudioFileWriterError.mapping(error)
        }
    }

    func close() {
        file = nil
    }
}
