@preconcurrency import AVFAudio
import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit

enum ScreenCaptureKitSourceError: Error {
    case alreadyStarted
    case noDisplays
    case streamCreationFailed(Error)
    case startCaptureFailed(Error)
}

actor ScreenCaptureKitSource: AudioSource {
    static let archivalFormat: AVAudioFormat = MicrophoneSource.archivalFormat

    private var stream: SCStream?
    private var output: SCKAudioOutput?
    private var tapHandler: SCKTapHandler?

    nonisolated let sttStream: AsyncStream<PCMChunk>
    private nonisolated let sttContinuation: AsyncStream<PCMChunk>.Continuation
    nonisolated let errorStream: AsyncStream<MeetingError>
    private nonisolated let errorContinuation: AsyncStream<MeetingError>.Continuation

    init() {
        var sttCont: AsyncStream<PCMChunk>.Continuation?
        let sttStream = AsyncStream<PCMChunk>(bufferingPolicy: .bufferingNewest(64)) { cont in
            sttCont = cont
        }
        self.sttStream = sttStream
        guard let sttCaptured = sttCont else {
            preconditionFailure("AsyncStream did not yield continuation")
        }
        sttContinuation = sttCaptured

        var errCont: AsyncStream<MeetingError>.Continuation?
        let errStream = AsyncStream<MeetingError>(bufferingPolicy: .bufferingNewest(8)) { cont in
            errCont = cont
        }
        errorStream = errStream
        guard let errCaptured = errCont else {
            preconditionFailure("AsyncStream did not yield continuation")
        }
        errorContinuation = errCaptured
    }

    func start(archivalURL: URL) async throws {
        guard stream == nil else { throw ScreenCaptureKitSourceError.alreadyStarted }
        let filter = try await Self.contentFilter()
        let config = Self.streamConfiguration()
        let handler = try makeTapHandler(archivalURL: archivalURL)
        let scStream = SCStream(filter: filter, configuration: config, delegate: nil)
        let output = SCKAudioOutput(handler: handler)
        do {
            try scStream.addStreamOutput(
                output,
                type: .audio,
                sampleHandlerQueue: DispatchQueue(label: "com.anandthakur.execa.sck.audio")
            )
        } catch {
            handler.close()
            throw ScreenCaptureKitSourceError.streamCreationFailed(error)
        }
        do {
            try await scStream.startCapture()
        } catch {
            handler.close()
            throw ScreenCaptureKitSourceError.startCaptureFailed(error)
        }
        stream = scStream
        self.output = output
        tapHandler = handler
    }

    private func makeTapHandler(archivalURL: URL) throws -> SCKTapHandler {
        let errorContinuation = errorContinuation
        let writer = try AudioFileWriter(
            url: archivalURL,
            format: Self.archivalFormat,
            onError: { error in
                if error == .diskFull { errorContinuation.yield(.diskFull) }
            }
        )
        return SCKTapHandler(
            archivalWriter: writer,
            archivalFormat: Self.archivalFormat,
            sttContinuation: sttContinuation
        )
    }

    private static func contentFilter() async throws -> SCContentFilter {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            throw ScreenCaptureKitSourceError.streamCreationFailed(error)
        }
        guard let display = content.displays.first else {
            throw ScreenCaptureKitSourceError.noDisplays
        }
        return SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
    }

    private static func streamConfiguration() -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        // Video frames are unused for audio-only capture; minimise their cost.
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.width = 2
        config.height = 2
        return config
    }

    func stop() async {
        if let scStream = stream {
            try? await scStream.stopCapture()
        }
        tapHandler?.close()
        stream = nil
        output = nil
        tapHandler = nil
    }
}

final class SCKAudioOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private let handler: SCKTapHandler

    init(handler: SCKTapHandler) {
        self.handler = handler
    }

    func stream(_: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        handler.handle(sampleBuffer: sampleBuffer)
    }
}

final class SCKTapHandler: @unchecked Sendable {
    private let lock = NSLock()
    private let archivalWriter: AudioFileWriter
    private let archivalFormat: AVAudioFormat
    private let sttContinuation: AsyncStream<PCMChunk>.Continuation

    private var archivalConverter: AVAudioConverter?
    private var sttResampler: AudioResampler?
    private var lastInputFormat: AVAudioFormat?
    private var closed = false

    init(
        archivalWriter: AudioFileWriter,
        archivalFormat: AVAudioFormat,
        sttContinuation: AsyncStream<PCMChunk>.Continuation
    ) {
        self.archivalWriter = archivalWriter
        self.archivalFormat = archivalFormat
        self.sttContinuation = sttContinuation
    }

    func close() {
        lock.lock()
        closed = true
        lock.unlock()
        archivalWriter.close()
        sttContinuation.finish()
    }

    func handle(sampleBuffer: CMSampleBuffer) {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        lock.unlock()

        guard let pcmBuffer = Self.makePCMBuffer(from: sampleBuffer) else { return }

        lock.lock()
        if lastInputFormat != pcmBuffer.format {
            archivalConverter = AVAudioConverter(from: pcmBuffer.format, to: archivalFormat)
            sttResampler = try? AudioResampler(inputFormat: pcmBuffer.format)
            lastInputFormat = pcmBuffer.format
        }
        let archivalConverter = archivalConverter
        let sttResampler = sttResampler
        lock.unlock()

        if let archivalConverter, let archivalBuffer = Self.convert(
            buffer: pcmBuffer,
            converter: archivalConverter,
            outputFormat: archivalFormat
        ) {
            try? archivalWriter.write(archivalBuffer)
        }

        if let sttResampler,
           let sttBuffer = try? sttResampler.convert(pcmBuffer),
           let audioBuffer = Self.pcmChunk(from: sttBuffer, source: .system) {
            sttContinuation.yield(audioBuffer)
        }
    }

    private static func makePCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return nil
        }
        guard let format = AVAudioFormat(streamDescription: asbdPtr) else { return nil }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0 else { return nil }

        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        pcmBuffer.frameLength = frameCount

        var blockBuffer: CMBlockBuffer?
        var abl = AudioBufferList()
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &abl,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == 0 else { return nil }

        // The AudioBufferList we got back is a single-element struct in Swift
        // (mNumberBuffers + mBuffers). For the multi-channel non-interleaved
        // case its real layout is mBuffers as a flexible array. Walk it via
        // unsafe pointer arithmetic and copy each channel into pcmBuffer.
        let outList = pcmBuffer.mutableAudioBufferList
        let inCount = Int(abl.mNumberBuffers)
        let outCount = Int(outList.pointee.mNumberBuffers)
        let inBuffers = withUnsafePointer(to: &abl.mBuffers) { ptr in
            UnsafeBufferPointer(start: ptr, count: inCount)
        }
        let outBuffers = withUnsafeMutablePointer(to: &outList.pointee.mBuffers) { ptr in
            UnsafeMutableBufferPointer(start: ptr, count: outCount)
        }
        for index in 0 ..< min(inCount, outCount) {
            guard let src = inBuffers[index].mData, let dst = outBuffers[index].mData else { continue }
            let bytes = Int(min(inBuffers[index].mDataByteSize, outBuffers[index].mDataByteSize))
            dst.copyMemory(from: src, byteCount: bytes)
        }
        return pcmBuffer
    }

    private static func convert(
        buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        outputFormat: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1)
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return nil
        }
        var consumed = false
        var convError: NSError?
        let status = converter.convert(to: output, error: &convError) { _, statusOut in
            if consumed {
                statusOut.pointee = .endOfStream
                return nil
            }
            consumed = true
            statusOut.pointee = .haveData
            return buffer
        }
        return status == .error ? nil : output
    }

    private static func pcmChunk(from buffer: AVAudioPCMBuffer, source: PCMChunk.Source) -> PCMChunk? {
        guard let channelData = buffer.int16ChannelData else { return nil }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else {
            return PCMChunk(
                source: source,
                sampleRate: buffer.format.sampleRate,
                channelCount: Int(buffer.format.channelCount),
                frameCount: 0,
                captureTime: Date(),
                samples: []
            )
        }
        var samples = [Int16](repeating: 0, count: frameCount)
        let pointer = channelData[0]
        for index in 0 ..< frameCount {
            samples[index] = pointer[index]
        }
        return PCMChunk(
            source: source,
            sampleRate: buffer.format.sampleRate,
            channelCount: Int(buffer.format.channelCount),
            frameCount: frameCount,
            captureTime: Date(),
            samples: samples
        )
    }
}
