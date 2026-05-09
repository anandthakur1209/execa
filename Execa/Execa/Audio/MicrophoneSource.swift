@preconcurrency import AVFAudio
import Foundation
import os

enum MicrophoneSourceError: Error {
    case alreadyStarted
    case engineStartFailed(Error)
    case formatUnavailable
}

/// Low-rate diagnostic logger: tap-fire totals and AVAudioEngine
/// configuration-change traces. Filterable in Console.app via subsystem
/// "com.anandthakur.execa" + category "audio.mic".
private let micLogger = Logger(subsystem: "com.anandthakur.execa", category: "audio.mic")

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

    /// `_sttStream` and `sttContinuation` are recreated on every
    /// `start(archivalURL:)` call. Meeting 1's `tapHandler.close()` calls
    /// `sttContinuation.finish()` to terminate any leftover consumer's
    /// for-await; Meeting 2 then needs a FRESH continuation to yield
    /// into, otherwise its tap handler's yields go to the void
    /// (AsyncStream.Continuation silently drops yields after `.finish()`).
    /// The `streamLock` synchronises access between the actor's
    /// `start(...)` mutator and the `nonisolated` `sttStream` getter.
    /// Pre-`start(...)` consumers see an idle initial stream that
    /// finishes the moment the first meeting starts.
    private nonisolated(unsafe) var _sttStream: AsyncStream<PCMChunk>
    private nonisolated(unsafe) var sttContinuation: AsyncStream<PCMChunk>.Continuation
    private nonisolated let streamLock = NSLock()

    nonisolated let errorStream: AsyncStream<MeetingError>
    private nonisolated let errorContinuation: AsyncStream<MeetingError>.Continuation

    init(bufferSize: AVAudioFrameCount = 4096) {
        self.bufferSize = bufferSize

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

    /// Returns the AsyncStream tied to the most recent `start(...)` call.
    /// Each meeting gets a fresh stream/continuation pair; consumers
    /// (`AudioCaptureService.micSttStream` → `TranscriptionService`) read
    /// this AFTER `start(...)` returns to pick up the per-meeting
    /// instance.
    nonisolated var sttStream: AsyncStream<PCMChunk> {
        streamLock.lock()
        defer { streamLock.unlock() }
        return _sttStream
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

        // Recreate the (sttStream, sttContinuation) pair for this
        // meeting. The previous continuation (if any — from a prior
        // meeting) is finished here so any lingering consumer's
        // for-await exits cleanly. The new tap handler captures the
        // fresh continuation; the new consumer (TranscriptionService
        // bridge for the next meeting) reads `sttStream` AFTER this
        // start returns and gets the fresh AsyncStream. See BUG 6 fix.
        let freshContinuation = recreateSttStreamPair()

        let handler = try makeTapHandler(
            archivalURL: archivalURL,
            inputFormat: inputFormat,
            sttContinuation: freshContinuation
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

        let rate = inputFormat.sampleRate
        let channels = inputFormat.channelCount
        micLogger.info(
            """
            mic engine started, inputFormat \
            sampleRate=\(rate, privacy: .public) \
            channels=\(channels, privacy: .public)
            """
        )
        installConfigurationChangeObserver(engine: engine)
    }

    /// Closes the existing `sttContinuation` (signals any prior consumer
    /// to exit) and creates a fresh `(AsyncStream, Continuation)` pair.
    /// Returns the new continuation for the caller (`start`) to hand
    /// to the new tap handler. The new `_sttStream` is now what
    /// `sttStream` returns to consumers.
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
        inputFormat: AVAudioFormat,
        sttContinuation: AsyncStream<PCMChunk>.Continuation
    ) throws -> MicrophoneTapHandler {
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
        return MicrophoneTapHandler(
            archivalWriter: writer,
            archivalConverter: archivalConverter,
            archivalFormat: Self.archivalFormat,
            sttResampler: sttResampler,
            sttContinuation: sttContinuation
        )
    }

    private func installConfigurationChangeObserver(engine: AVAudioEngine) {
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            // expected gap on device hot-swap: ~1 buffer is dropped while we
            // tear the tap down and rebuild for the new input format.
            micLogger.info("AVAudioEngineConfigurationChange notification observed")
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
        guard let engine, let handler = tapHandler else {
            micLogger.warning("config change: engine or handler nil, skipping")
            return
        }
        let inputNode = engine.inputNode
        engine.stop()
        inputNode.removeTap(onBus: 0)

        let newFormat = inputNode.outputFormat(forBus: 0)
        let newRate = newFormat.sampleRate
        let newChannels = newFormat.channelCount
        micLogger.info(
            """
            config change: newFormat \
            sampleRate=\(newRate, privacy: .public) \
            channels=\(newChannels, privacy: .public)
            """
        )
        guard newFormat.sampleRate > 0 else {
            micLogger.warning("config change: degenerate sampleRate, ABORTING WITHOUT RESTART")
            return
        }
        let newArchivalConverter = AVAudioConverter(from: newFormat, to: Self.archivalFormat)
        guard let newSttResampler = try? AudioResampler(inputFormat: newFormat) else {
            micLogger.error("config change: resampler init failed, ABORTING WITHOUT RESTART")
            return
        }
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

    // Diagnostic counters (read under `lock`). Tap callbacks are the source of
    // truth for "did the audio thread keep firing?" — we surface totals at
    // close() so a regression where the tap dies after one buffer is
    // immediately visible in Console.app.
    private var fireCount = 0
    private var writeCount = 0

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
        fireCount += 1
        let count = fireCount
        let archivalConverter = archivalConverter
        let sttResampler = sttResampler
        let isClosed = closed
        lock.unlock()
        guard !isClosed else { return }

        if count == 1 || count % 100 == 0 {
            micLogger.debug("mic tap fire #\(count, privacy: .public) frames=\(buffer.frameLength, privacy: .public)")
        }

        if let archivalConverter, let archivalBuffer = Self.convert(
            buffer: buffer,
            converter: archivalConverter,
            outputFormat: archivalFormat
        ) {
            do {
                try archivalWriter.write(archivalBuffer)
                lock.lock()
                writeCount += 1
                lock.unlock()
            } catch {
                let description = String(describing: error)
                micLogger.error(
                    "mic archival write failed at fire #\(count, privacy: .public): \(description, privacy: .public)"
                )
            }
        }

        if let sttBuffer = try? sttResampler.convert(buffer),
           let audioBuffer = Self.pcmChunk(from: sttBuffer, source: .mic) {
            sttContinuation.yield(audioBuffer)
        }
    }

    func close() {
        lock.lock()
        closed = true
        let fires = fireCount
        let writes = writeCount
        lock.unlock()
        micLogger.info("mic tap closing: total fires=\(fires, privacy: .public) writes=\(writes, privacy: .public)")
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
