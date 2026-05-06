import AudioToolbox
@preconcurrency import AVFAudio
import Foundation

enum AudioMixerError: Error {
    case openFailed(URL, Error)
    case writeFailed(Error)
    case formatFailed
}

enum AudioMixer {
    static let outputSampleRate: Double = 48000

    /// Reads mic.wav and system.wav, sums them sample-by-sample (mic + system) / 2,
    /// and writes a 48 kHz Int16 mono FLAC at `output`. Either input may be
    /// shorter or empty; missing tail is treated as silence. An entirely empty
    /// pair still produces a valid one-frame FLAC so the file is structurally
    /// sound for downstream re-processing.
    ///
    /// FIXME(phase-5): per-source first-frame timestamp alignment. Today this
    /// aligns from frame 0 of each source, so any startup-latency difference
    /// between mic and system shows up as lip-sync drift in master.flac. The
    /// archival .wav files are timestamp-tagged via PCMChunk.captureTime; the
    /// fix is to consult that wall-clock anchor and pad the lagging source's
    /// head with silence to align. Drift in Phase 1 measures < ~100 ms and
    /// remains acceptable for archival; Phase 5 history-view playback is
    /// where the mismatch becomes audible. Tracked in BUILD_PLAN.md.
    static func writeMasterFLAC(micWAV: URL, systemWAV: URL, output: URL) throws {
        let micFile = Self.openIfExists(micWAV)
        let systemFile = Self.openIfExists(systemWAV)

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: outputSampleRate,
            channels: 1,
            interleaved: true
        ) else {
            throw AudioMixerError.formatFailed
        }

        let outFile: AVAudioFile
        do {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatFLAC,
                AVSampleRateKey: outputSampleRate,
                AVNumberOfChannelsKey: 1
            ]
            outFile = try AVAudioFile(
                forWriting: output,
                settings: settings,
                commonFormat: .pcmFormatInt16,
                interleaved: true
            )
        } catch {
            throw AudioMixerError.writeFailed(error)
        }

        // For empty inputs (sources emitted no buffers before stop), we still
        // produce a structurally valid FLAC by emitting one second of silence.
        // FLAC's per-block format and AVFAudio's reopen path both need more
        // than a single block of audio to be reliably parseable.
        let chunkFrames: AVAudioFrameCount = 4096
        let observedFrames = max(micFile?.length ?? 0, systemFile?.length ?? 0)
        let totalFrames = observedFrames > 0
            ? observedFrames
            : AVAudioFramePosition(outputSampleRate)
        var remaining = totalFrames
        while remaining > 0 {
            let frames = AVAudioFrameCount(min(AVAudioFramePosition(chunkFrames), remaining))
            let micChunk = try Self.read(file: micFile, frames: frames, target: outputFormat)
            let systemChunk = try Self.read(file: systemFile, frames: frames, target: outputFormat)
            guard let mixed = Self.mix(mic: micChunk, system: systemChunk, frames: frames, format: outputFormat) else {
                throw AudioMixerError.writeFailed(NSError(domain: "AudioMixer", code: -1))
            }
            do {
                try outFile.write(from: mixed)
            } catch {
                throw AudioMixerError.writeFailed(error)
            }
            remaining -= AVAudioFramePosition(frames)
        }
    }

    private static func openIfExists(_ url: URL) -> AVAudioFile? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        // A 0-byte WAV (source emitted no frames before stop) is not an error
        // from a recording-lifecycle perspective; treat as silent.
        return try? AVAudioFile(forReading: url)
    }

    /// Reads up to `frames` frames from `file` into a target-format buffer
    /// of length exactly `frames`. Past EOF, missing source, and any other
    /// read failure resolves to silence — the mixer must produce aligned
    /// output even when one source is shorter or absent.
    private static func read(
        file: AVAudioFile?,
        frames: AVAudioFrameCount,
        target: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: frames) else {
            throw AudioMixerError.formatFailed
        }
        // PCMBuffer memory is zero-initialised; silence-pad paths leave it alone.
        buffer.frameLength = frames
        guard let file else { return buffer }

        guard let nativeBuffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: frames
        ) else {
            throw AudioMixerError.formatFailed
        }
        do {
            try file.read(into: nativeBuffer, frameCount: frames)
        } catch {
            nativeBuffer.frameLength = 0
        }
        if nativeBuffer.frameLength == 0 { return buffer }

        if nativeBuffer.format == target {
            copyInt16Samples(from: nativeBuffer, to: buffer)
            return buffer
        }
        try convert(nativeBuffer: nativeBuffer, into: buffer, frames: frames, target: target)
        return buffer
    }

    private static func copyInt16Samples(from src: AVAudioPCMBuffer, to dst: AVAudioPCMBuffer) {
        guard let srcData = src.int16ChannelData, let dstData = dst.int16ChannelData else { return }
        for index in 0 ..< Int(src.frameLength) {
            dstData[0][index] = srcData[0][index]
        }
    }

    private static func convert(
        nativeBuffer: AVAudioPCMBuffer,
        into buffer: AVAudioPCMBuffer,
        frames: AVAudioFrameCount,
        target: AVAudioFormat
    ) throws {
        guard let converter = AVAudioConverter(from: nativeBuffer.format, to: target) else {
            throw AudioMixerError.formatFailed
        }
        var consumed = false
        var convError: NSError?
        let status = converter.convert(to: buffer, error: &convError) { _, statusOut in
            if consumed {
                statusOut.pointee = .endOfStream
                return nil
            }
            consumed = true
            statusOut.pointee = .haveData
            return nativeBuffer
        }
        if status == .error {
            throw AudioMixerError.writeFailed(convError ?? NSError(domain: "AudioMixer", code: -2))
        }
        buffer.frameLength = frames
    }

    private static func mix(
        mic: AVAudioPCMBuffer,
        system: AVAudioPCMBuffer,
        frames: AVAudioFrameCount,
        format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        guard let micPointer = mic.int16ChannelData,
              let systemPointer = system.int16ChannelData,
              let outPointer = buffer.int16ChannelData
        else {
            return nil
        }
        for index in 0 ..< Int(frames) {
            let summed = Int32(micPointer[0][index]) + Int32(systemPointer[0][index])
            outPointer[0][index] = Int16(clamping: summed / 2)
        }
        return buffer
    }
}
