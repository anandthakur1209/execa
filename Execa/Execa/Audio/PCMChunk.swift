import Foundation

/// Sendable PCM payload that flows through the STT-format pipeline. Distinct
/// from CoreAudio's AudioBuffer C struct (used inside AudioBufferList) and from
/// AVAudioPCMBuffer (which carries the archival path inside source actors).
struct PCMChunk: Equatable {
    enum Source: String, Equatable {
        case mic
        case system
    }

    let source: Source
    let sampleRate: Double
    let channelCount: Int
    let frameCount: Int
    let captureTime: Date
    let samples: [Int16]
}
