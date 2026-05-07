import AVFAudio
import CoreGraphics
@testable import Execa
import Foundation
import Testing

struct ScreenCaptureKitSourceTests {
    /// Permission-gated. Requires Screen Recording authorization for the test
    /// host. Exits early without failing if not authorized.
    ///
    /// Regression contract: the SCStream must keep delivering audio buffers
    /// for the full capture window. A frame-count >= 0.5 * (sampleRate *
    /// captureSeconds) gate catches the "callback dies after one buffer"
    /// failure mode. SCK silence-elision can shave the floor a little
    /// further than AVAudioEngine, so the threshold is more lenient.
    @Test func capturesSystemAudioToWAV() async throws {
        guard CGPreflightScreenCaptureAccess() else { return }

        let dir = try MeetingsDirectory.url(forMeetingID: "sck-test-\(ULID.generate())")
        let url = dir.appendingPathComponent("system.wav")
        defer { try? FileManager.default.removeItem(at: dir) }

        let captureSeconds = 2.0
        let source = ScreenCaptureKitSource()
        try await source.start(archivalURL: url)
        try await Task.sleep(nanoseconds: UInt64(captureSeconds * 1_000_000_000))
        await source.stop()

        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.sampleRate == 48000)
        #expect(file.fileFormat.channelCount == 1)

        let expectedFrames = AVAudioFramePosition(file.fileFormat.sampleRate * captureSeconds)
        let minimumFrames = AVAudioFramePosition(Double(expectedFrames) * 0.5)
        #expect(
            file.length >= minimumFrames,
            """
            expected system.wav frames >= \(minimumFrames) (50% of \(expectedFrames)) but got \(file.length); \
            SCStream likely stopped delivering buffers mid-capture
            """
        )
    }
}
