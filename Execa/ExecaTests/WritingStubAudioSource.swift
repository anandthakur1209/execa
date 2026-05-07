import AVFAudio
@testable import Execa
import Foundation

/// Deterministic test double that opens an AudioFileWriter and emits a fixed
/// number of synthetic PCM buffers across a fixed window. Unlike StubAudioSource
/// (which does no I/O), this stub exercises the file-writing pipeline so that
/// regressions in either AudioFileWriter or the AudioCaptureService stop
/// sequence land in `mic.wav`/`system.wav` and are observable post-stop.
///
/// This is the test we wished we had when audio capture quietly stopped after
/// one buffer in Phase 1 manual smoke: a stub that emits N buffers and asserts
/// they all land on disk would have caught the regression.
actor WritingStubAudioSource: AudioSource {
    nonisolated let sttStream: AsyncStream<PCMChunk>
    private nonisolated let sttContinuation: AsyncStream<PCMChunk>.Continuation
    nonisolated let errorStream: AsyncStream<MeetingError>
    private nonisolated let errorContinuation: AsyncStream<MeetingError>.Continuation

    private let bufferCount: Int
    private let framesPerBuffer: AVAudioFrameCount
    private let intervalNanoseconds: UInt64
    private var writer: AudioFileWriter?
    private var emitterTask: Task<Void, Never>?

    /// - Parameters:
    ///   - bufferCount: total number of synthetic buffers to emit.
    ///   - framesPerBuffer: frames in each buffer (480 = 10 ms @ 48 kHz).
    ///   - intervalMs: spacing between emissions (10 ms by default → 100
    ///     buffers in 1 s, matching a typical mic tap rate).
    init(
        bufferCount: Int = 100,
        framesPerBuffer: AVAudioFrameCount = 480,
        intervalMs: UInt64 = 10
    ) {
        self.bufferCount = bufferCount
        self.framesPerBuffer = framesPerBuffer
        intervalNanoseconds = intervalMs * 1_000_000

        var sttCont: AsyncStream<PCMChunk>.Continuation?
        let stream = AsyncStream<PCMChunk> { cont in sttCont = cont }
        sttStream = stream
        guard let sttCaptured = sttCont else {
            preconditionFailure("AsyncStream did not yield continuation")
        }
        sttContinuation = sttCaptured

        var errCont: AsyncStream<MeetingError>.Continuation?
        let errStream = AsyncStream<MeetingError> { cont in errCont = cont }
        errorStream = errStream
        guard let errCaptured = errCont else {
            preconditionFailure("AsyncStream did not yield continuation")
        }
        errorContinuation = errCaptured
    }

    func start(archivalURL: URL) async throws {
        let format = MicrophoneSource.archivalFormat
        let writer = try AudioFileWriter(url: archivalURL, format: format)
        self.writer = writer

        let count = bufferCount
        let frames = framesPerBuffer
        let interval = intervalNanoseconds
        emitterTask = Task.detached(priority: .userInitiated) { [weak self] in
            for index in 0 ..< count {
                if Task.isCancelled { return }
                guard let buffer = Self.makeSineBuffer(format: format, frames: frames, index: index) else { continue }
                do {
                    try writer.write(buffer)
                } catch {
                    return
                }
                try? await Task.sleep(nanoseconds: interval)
            }
            _ = self // keep self alive until the loop ends
        }
    }

    func stop() async {
        emitterTask?.cancel()
        await emitterTask?.value
        emitterTask = nil
        writer?.close()
        writer = nil
        sttContinuation.finish()
        errorContinuation.finish()
    }

    private static func makeSineBuffer(
        format: AVAudioFormat,
        frames: AVAudioFrameCount,
        index: Int
    ) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        guard let channelData = buffer.int16ChannelData else { return nil }
        let pointer = channelData[0]
        let amplitude: Double = 8000
        let phaseOffset = Double(index) * Double(frames)
        for sampleIndex in 0 ..< Int(frames) {
            let phase = (phaseOffset + Double(sampleIndex)) / format.sampleRate * 2 * .pi * 440
            pointer[sampleIndex] = Int16(amplitude * sin(phase))
        }
        return buffer
    }
}
