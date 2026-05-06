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

/// AVAudioFile is reference-typed and not thread-safe, but AVFAudio guarantees
/// single-thread-write safety. The audio tap thread is the sole writer; close()
/// is called from the source actor on stop and releases the AVAudioFile so its
/// deinit flushes the underlying AudioFileClose. The lock guards the brief
/// window where a stale buffer could land after close.
final nonisolated class AudioFileWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var file: AVAudioFile?

    init(url: URL, format: AVAudioFormat) throws {
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
        lock.lock()
        defer { lock.unlock() }
        guard let file else { return }
        do {
            try file.write(from: buffer)
        } catch {
            throw AudioFileWriterError.mapping(error)
        }
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        file = nil
    }
}
