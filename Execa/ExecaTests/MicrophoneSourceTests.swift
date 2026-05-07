import AVFAudio
import AVFoundation
@testable import Execa
import Foundation
import Testing

struct MicrophoneSourceTests {
    /// Permission-gated. If microphone access is not authorized for the test
    /// host (Xcode / xcodebuild), the test exits early without failing — this
    /// matches the Phase 1 plan's "skipped if denied" requirement.
    ///
    /// Regression contract: the tap must keep firing for the entire capture
    /// window. A frame-count >= 0.6 * (sampleRate * captureSeconds) gate
    /// catches the "tap dies after one buffer" failure mode (which previously
    /// produced a structurally-correct mic.wav of ~0.1 s while we recorded for
    /// many seconds). 0.6 leaves headroom for AVAudioEngine startup latency
    /// (~200 ms is normal on macOS) without making the test flaky.
    @Test func capturesAudioToWAV() async throws {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        guard status == .authorized else { return }

        let url = try MeetingsDirectory.url(forMeetingID: "mic-test-\(ULID.generate())")
            .appendingPathComponent("mic.wav")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let captureSeconds = 1.5
        let source = MicrophoneSource()
        try await source.start(archivalURL: url)
        try await Task.sleep(nanoseconds: UInt64(captureSeconds * 1_000_000_000))
        await source.stop()

        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.sampleRate == 48000)
        #expect(file.fileFormat.channelCount == 1)

        let expectedFrames = AVAudioFramePosition(file.fileFormat.sampleRate * captureSeconds)
        let minimumFrames = AVAudioFramePosition(Double(expectedFrames) * 0.6)
        #expect(
            file.length >= minimumFrames,
            """
            expected mic.wav frames >= \(minimumFrames) (60% of \(expectedFrames)) but got \(file.length); \
            the tap likely stopped firing mid-capture
            """
        )
    }
}
