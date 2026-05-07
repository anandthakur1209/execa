@preconcurrency import AVFAudio
import Foundation

enum MicrophoneSourceError: Error {
    case alreadyStarted
    case engineStartFailed(Error)
    case formatUnavailable
}

actor MicrophoneSource: AudioSource {
    static let archivalFormat: AVAudioFormat = {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 48000,
            channels: 1,
            interleaved: true
        ) else {
            preconditionFailure("48 kHz Int16 mono format failed to construct")
        }
        return format
    }()

    private let bufferSize: AVAudioFrameCount
    private var engine: AVAudioEngine?
    private var tapHandler: MicrophoneTapHandler?
    private var configChangeObserver: NSObjectProtocol?
    private var archivalURL: URL?

    nonisolated let sttStream: AsyncStream<PCMChunk>
    private nonisolated let sttContinuation: AsyncStream<PCMChunk>.Continuation
    nonisolated let errorStream: AsyncStream<MeetingError>
    private nonisolated let errorContinuation: AsyncStream<MeetingError>.Continuation

    init(bufferSize: AVAudioFrameCount = 4096) {
        self.bufferSize = bufferSize
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
        guard engine == nil else { throw MicrophoneSourceError.alreadyStarted }
        self.archivalURL = archivalURL

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw MicrophoneSourceError.formatUnavailable
        }

        let errorContinuation = errorContinuation
        let writer = try AudioFileWriter(
            url: archivalURL,
            format: Self.archivalFormat,
            onError: { error in
                if error == .diskFull {
                    errorContinuation.yield(.diskFull)
                }
            }
        )
        let archivalConverter = AVAudioConverter(from: inputFormat, to: Self.archivalFormat)
        let sttResampler = try AudioResampler(inputFormat: inputFormat)

        let handler = MicrophoneTapHandler(
            archivalWriter: writer,
            archivalConverter: archivalConverter,
            archivalFormat: Self.archivalFormat,
            sttResampler: sttResampler,
            sttContinuation: sttContinuation
        )
        tapHandler = handler

        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { buffer, time in
            handler.handle(buffer: buffer, time: time)
        }

        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            handler.close()
            tapHandler = nil
            throw MicrophoneSourceError.engineStartFailed(error)
        }
        self.engine = engine

        configChangeObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            // expected gap on device hot-swap: ~1 buffer is dropped while we
            // tear the tap down and rebuild for the new input format.
            Task { [weak self] in await self?.handleConfigurationChange() }
        }
    }

    func stop() async {
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        tapHandler?.close()
        tapHandler = nil
        engine = nil
        archivalURL = nil
    }

    private func handleConfigurationChange() async {
        guard let engine, let handler = tapHandler else { return }
        let inputNode = engine.inputNode
        engine.stop()
        inputNode.removeTap(onBus: 0)

        let newFormat = inputNode.outputFormat(forBus: 0)
        guard newFormat.sampleRate > 0 else { return }
        let newArchivalConverter = AVAudioConverter(from: newFormat, to: Self.archivalFormat)
        guard let newSttResampler = try? AudioResampler(inputFormat: newFormat) else { return }
        handler.update(archivalConverter: newArchivalConverter, sttResampler: newSttResampler)

        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: newFormat) { buffer, time in
            handler.handle(buffer: buffer, time: time)
        }
        try? engine.start()
    }
}

// TODO: macOS 15 path — once we raise the deployment target, replace
// AVAudioEngine here with SCStream.captureMicrophone for a unified SCK
// pipeline. Public surface stays the same.
final nonisolated class MicrophoneTapHandler: @unchecked Sendable {
    private let lock = NSLock()
    private let archivalWriter: AudioFileWriter
    private let archivalFormat: AVAudioFormat
    private var archivalConverter: AVAudioConverter?
    private var sttResampler: AudioResampler
    private let sttContinuation: AsyncStream<PCMChunk>.Continuation
    private var closed = false

    init(
        archivalWriter: AudioFileWriter,
        archivalConverter: AVAudioConverter?,
        archivalFormat: AVAudioFormat,
        sttResampler: AudioResampler,
        sttContinuation: AsyncStream<PCMChunk>.Continuation
    ) {
        self.archivalWriter = archivalWriter
        self.archivalConverter = archivalConverter
        self.archivalFormat = archivalFormat
        self.sttResampler = sttResampler
        self.sttContinuation = sttContinuation
    }

    func update(archivalConverter: AVAudioConverter?, sttResampler: AudioResampler) {
        lock.lock()
        defer { lock.unlock() }
        self.archivalConverter = archivalConverter
        self.sttResampler = sttResampler
    }

    func handle(buffer: AVAudioPCMBuffer, time _: AVAudioTime) {
        lock.lock()
        let archivalConverter = archivalConverter
        let sttResampler = sttResampler
        let isClosed = closed
        lock.unlock()
        guard !isClosed else { return }

        if let archivalConverter, let archivalBuffer = Self.convert(
            buffer: buffer,
            converter: archivalConverter,
            outputFormat: archivalFormat
        ) {
            try? archivalWriter.write(archivalBuffer)
        }

        if let sttBuffer = try? sttResampler.convert(buffer),
           let audioBuffer = Self.pcmChunk(from: sttBuffer, source: .mic) {
            sttContinuation.yield(audioBuffer)
        }
    }

    func close() {
        lock.lock()
        closed = true
        lock.unlock()
        archivalWriter.close()
        sttContinuation.finish()
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
