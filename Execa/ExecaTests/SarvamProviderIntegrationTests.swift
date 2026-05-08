import AVFAudio
@testable import Execa
import Foundation
import Testing

/// Drives a real `SarvamProvider` against the live Sarvam streaming
/// endpoint with `Fixtures/hello.wav`. Permission-gated on a Keychain
/// entry: skipped silently if no key is stored, so a fresh dev machine
/// or CI doesn't hard-fail.
///
/// What it asserts: at least one `.final` event arrives within the test
/// window with non-empty transcript text. Doesn't assert the exact
/// transcript (Sarvam may transcribe the same audio slightly differently
/// across runs); just that the wire path works end-to-end.
struct SarvamProviderIntegrationTests {
    @Test func endToEndFinalsForHelloWav() async throws {
        let keychain = KeychainStore()
        let service = KeychainStore.serviceName(forProvider: "sarvam")
        guard let key = (try? keychain.get(service: service, account: "default")), !key.isEmpty else {
            // Skip on machines without a key.
            return
        }

        let bundle = Bundle(for: BundleAnchor.self)
        guard let wavURL = bundle.url(forResource: "hello", withExtension: "wav") else {
            Issue.record("missing Fixtures/hello.wav in test bundle")
            return
        }
        let chunks = try Self.loadChunks(wavURL: wavURL)
        let (audioStream, audioCont) = AsyncStream<PCMChunk>.makeStream()

        let provider = SarvamProvider(apiKey: key)
        try await provider.start(meetingID: "integration-test", source: .mic, audioStream: audioStream)

        // Pump chunks every 100 ms — same cadence the official Sarvam
        // sample uses. Pad with 2 s of silence so VAD detects an
        // end-of-utterance and Sarvam emits its transcript.
        let silenceChunks = Self.silenceChunks(seconds: 2, samplesPerChunk: 1600)
        let producer = Task<Void, Never> {
            for chunk in chunks + silenceChunks {
                audioCont.yield(chunk)
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            audioCont.finish()
        }

        // Drain events. Exits as soon as we see a non-empty final, or when
        // the events stream closes (after provider.stop()), or when the
        // 30 s safety deadline elapses.
        let drain = Task<Bool, Never> {
            for await event in provider.events {
                if case let .final(token) = event, !token.text.isEmpty {
                    return true
                }
            }
            return false
        }

        // Wait for producer + a short grace window for the round-trip,
        // then stop the provider. provider.stop() finishes the events
        // continuation, which unblocks the drain task.
        await producer.value
        try await Task.sleep(nanoseconds: 4_000_000_000)
        await provider.stop()

        let sawFinal = await drain.value
        #expect(sawFinal, "expected at least one .final TranscriptionEvent for hello.wav")
    }

    // MARK: - Helpers

    private static func loadChunks(wavURL: URL) throws -> [PCMChunk] {
        // Force Int16 read format: AVAudioFile defaults processingFormat to
        // Float32, which makes `buffer.int16ChannelData` nil and silently
        // produces zero chunks.
        let file = try AVAudioFile(
            forReading: wavURL,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )
        let format = file.processingFormat
        let totalFrames = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames) else {
            return []
        }
        try file.read(into: buffer)

        let sampleRate = Int(format.sampleRate)
        let samplesPerChunk = sampleRate / 10 // 100 ms cadence
        var chunks: [PCMChunk] = []
        let frameCount = Int(buffer.frameLength)
        guard let int16 = buffer.int16ChannelData?[0] else { return [] }

        var offset = 0
        while offset < frameCount {
            let end = min(offset + samplesPerChunk, frameCount)
            let count = end - offset
            var samples = [Int16](repeating: 0, count: count)
            for index in 0 ..< count {
                samples[index] = int16[offset + index]
            }
            chunks.append(PCMChunk(
                source: .mic,
                sampleRate: format.sampleRate,
                channelCount: 1,
                frameCount: count,
                captureTime: Date(),
                samples: samples
            ))
            offset = end
        }
        return chunks
    }

    private static func silenceChunks(seconds: Int, samplesPerChunk: Int) -> [PCMChunk] {
        let chunksPerSecond = 16000 / samplesPerChunk
        return (0 ..< seconds * chunksPerSecond).map { _ in
            PCMChunk(
                source: .mic,
                sampleRate: 16000,
                channelCount: 1,
                frameCount: samplesPerChunk,
                captureTime: Date(),
                samples: [Int16](repeating: 0, count: samplesPerChunk)
            )
        }
    }
}

private final class BundleAnchor {}
