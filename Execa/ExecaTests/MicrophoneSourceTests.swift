import AVFAudio
import AVFoundation
@testable import Execa
import Foundation
import Testing

struct MicrophoneSourceTests {
    /// Permission-gated. If microphone access is not authorized for the test
    /// host (Xcode / xcodebuild), the test exits early without failing — this
    /// matches the Phase 1 plan's "skipped if denied" requirement.
    @Test func capturesAudioToWAV() async throws {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        guard status == .authorized else { return }

        let url = try MeetingsDirectory.url(forMeetingID: "mic-test-\(ULID.generate())")
            .appendingPathComponent("mic.wav")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let source = MicrophoneSource()
        try await source.start(archivalURL: url)
        try await Task.sleep(nanoseconds: 500_000_000)
        await source.stop()

        let file = try AVAudioFile(forReading: url)
        #expect(file.length > 0, "expected non-empty mic.wav after 0.5 s of capture")
        #expect(file.fileFormat.sampleRate == 48000)
        #expect(file.fileFormat.channelCount == 1)
    }
}
