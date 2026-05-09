@preconcurrency import AVFAudio
import CoreMedia
import Foundation
import os
@preconcurrency import ScreenCaptureKit

enum ScreenCaptureKitSourceError: Error {
    case alreadyStarted
    case noDisplays
    case streamCreationFailed(Error)
    case startCaptureFailed(Error)
}

/// Low-rate diagnostic logger for SCStream callbacks. Filterable in
/// Console.app via subsystem "com.anandthakur.execa" + category "audio.sck".
private let sckLogger = Logger(subsystem: "com.anandthakur.execa", category: "audio.sck")

actor ScreenCaptureKitSource: AudioSource {
    static let archivalFormat: AVAudioFormat = MicrophoneSource.archivalFormat

    private var stream: SCStream?
    private var output: SCKAudioOutput?
    private var tapHandler: SCKTapHandler?

    /// Per-meeting `(AsyncStream, Continuation)` pair. See the matching
    /// comment + design rationale on `MicrophoneSource._sttStream` —
    /// same back-to-back-meetings BUG 6 fix applies here. Meeting 1's
    /// `SCKTapHandler.close()` finishes the previous continuation;
    /// Meeting 2's fresh tap handler captures the new one created in
    /// `start(...)`.
    private nonisolated(unsafe) var _sttStream: AsyncStream<PCMChunk>
    private nonisolated(unsafe) var sttContinuation: AsyncStream<PCMChunk>.Continuation
    private nonisolated let streamLock = NSLock()

    nonisolated let errorStream: AsyncStream<MeetingError>
    private nonisolated let errorContinuation: AsyncStream<MeetingError>.Continuation

    init() {
        var sttCont: AsyncStream<PCMChunk>.Continuation?
        let initialStream = AsyncStream<PCMChunk>(bufferingPolicy: .bufferingNewest(64)) { cont in
            sttCont = cont
        }
        _sttStream = initialStream
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

    nonisolated var sttStream: AsyncStream<PCMChunk> {
        streamLock.lock()
        defer { streamLock.unlock() }
        return _sttStream
    }

    func start(archivalURL: URL) async throws {
        guard stream == nil else { throw ScreenCaptureKitSourceError.alreadyStarted }
        let filter = try await Self.contentFilter()
        let config = Self.streamConfiguration()
        // Recreate the (sttStream, sttContinuation) pair for this meeting
        // — see MicrophoneSource for design rationale (BUG 6 fix).
        let freshContinuation = recreateSttStreamPair()
        let handler = try makeTapHandler(archivalURL: archivalURL, sttContinuation: freshContinuation)
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

    /// Closes the existing `sttContinuation` (signals any prior consumer
    /// to exit) and creates a fresh `(AsyncStream, Continuation)` pair.
    /// Returns the new continuation for the caller (`start`) to hand
    /// to the new SCKTapHandler.
    private func recreateSttStreamPair() -> AsyncStream<PCMChunk>.Continuation {
        var newCont: AsyncStream<PCMChunk>.Continuation?
        let newStream = AsyncStream<PCMChunk>(bufferingPolicy: .bufferingNewest(64)) { cont in
            newCont = cont
        }
        guard let captured = newCont else {
            preconditionFailure("AsyncStream did not yield continuation")
        }
        streamLock.lock()
        sttContinuation.finish()
        _sttStream = newStream
        sttContinuation = captured
        streamLock.unlock()
        return captured
    }

    private func makeTapHandler(
        archivalURL: URL,
        sttContinuation: AsyncStream<PCMChunk>.Continuation
    ) throws -> SCKTapHandler {
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
        if let output {
            sckLogger.info("sck stream output total fires=\(output.totalFireCount(), privacy: .public)")
        }
        tapHandler?.close()
        stream = nil
        output = nil
        tapHandler = nil
    }
}

final class SCKAudioOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private let handler: SCKTapHandler
    private let counterLock = NSLock()
    /// Diagnostic counter: incremented for every SCStream sample-buffer
    /// delivery. If callbacks stop firing prematurely (the bug we're hunting),
    /// this number caps out at 1 or 2.
    private var fireCount = 0

    init(handler: SCKTapHandler) {
        self.handler = handler
    }

    func stream(_: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        counterLock.lock()
        fireCount += 1
        let count = fireCount
        counterLock.unlock()
        if count == 1 || count % 100 == 0 {
            let frames = CMSampleBufferGetNumSamples(sampleBuffer)
            sckLogger.debug("sck audio fire #\(count, privacy: .public) frames=\(frames, privacy: .public)")
        }
        handler.handle(sampleBuffer: sampleBuffer)
    }

    func totalFireCount() -> Int {
        counterLock.lock()
        defer { counterLock.unlock() }
        return fireCount
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
    private var handleCount = 0
    private var writeCount = 0

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
        let handles = handleCount
        let writes = writeCount
        lock.unlock()
        sckLogger.info("sck tap closing: total handles=\(handles, privacy: .public) writes=\(writes, privacy: .public)")
        archivalWriter.close()
        sttContinuation.finish()
    }

    func handle(sampleBuffer: CMSampleBuffer) {
        lock.lock()
        handleCount += 1
        let handles = handleCount
        if closed {
            lock.unlock()
            return
        }
        lock.unlock()

        guard let pcmBuffer = Self.makePCMBuffer(from: sampleBuffer) else { return }

        let (archivalConverter, sttResampler) = refreshConverters(for: pcmBuffer.format)

        writeArchival(pcmBuffer: pcmBuffer, converter: archivalConverter, handles: handles)

        if let sttResampler,
           let sttBuffer = try? sttResampler.convert(pcmBuffer),
           let audioBuffer = Self.pcmChunk(from: sttBuffer, source: .system) {
            sttContinuation.yield(audioBuffer)
        }
    }

    /// Lock-protected access to the per-input-format converter / resampler.
    /// Recreates them when the incoming sample buffer's format changes
    /// (rare in practice, but guards against device-config changes).
    private func refreshConverters(for inputFormat: AVAudioFormat) -> (AVAudioConverter?, AudioResampler?) {
        lock.lock()
        defer { lock.unlock() }
        if lastInputFormat != inputFormat {
            archivalConverter = AVAudioConverter(from: inputFormat, to: archivalFormat)
            sttResampler = try? AudioResampler(inputFormat: inputFormat)
            lastInputFormat = inputFormat
        }
        return (archivalConverter, sttResampler)
    }

    private func writeArchival(pcmBuffer: AVAudioPCMBuffer, converter: AVAudioConverter?, handles: Int) {
        guard let converter, let archivalBuffer = Self.convert(
            buffer: pcmBuffer,
            converter: converter,
            outputFormat: archivalFormat
        ) else {
            if handles == 1 {
                let presence = converter != nil ? "present" : "nil"
                sckLogger.warning("sck convert nil at handle #1 (converter=\(presence, privacy: .public))")
            }
            return
        }
        if handles == 1 {
            let frames = pcmBuffer.frameLength
            let rate = pcmBuffer.format.sampleRate
            let channels = pcmBuffer.format.channelCount
            let outFrames = archivalBuffer.frameLength
            sckLogger.info(
                """
                sck first buffer inputFrames=\(frames, privacy: .public) \
                inputRate=\(rate, privacy: .public) \
                channels=\(channels, privacy: .public) \
                outputFrames=\(outFrames, privacy: .public)
                """
            )
        }
        do {
            try archivalWriter.write(archivalBuffer)
            lock.lock()
            writeCount += 1
            lock.unlock()
        } catch {
            let description = String(describing: error)
            sckLogger.error("sck archival write failed: \(description, privacy: .public)")
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

        // Copy the sample buffer's PCM data directly into pcmBuffer's
        // already-correctly-sized AudioBufferList. The previous implementation
        // used a stack-allocated single-buffer AudioBufferList struct, which
        // is undersized for non-interleaved multi-channel system audio (which
        // is what SCStream typically delivers). The undersized list caused
        // CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer to fail
        // silently, dropping every buffer.
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: pcmBuffer.mutableAudioBufferList
        )
        guard status == noErr else { return nil }
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
        // See AudioResampler.convert(_:) for why we use `.noDataNow` instead
        // of `.endOfStream` — `.endOfStream` permanently closes the converter
        // and turns every subsequent buffer into a 0-frame no-op.
        let status = converter.convert(to: output, error: &convError) { _, statusOut in
            if consumed {
                statusOut.pointee = .noDataNow
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
