import Foundation

struct AudioBuffer: Equatable {
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
