import AVFAudio
import CoreGraphics
@testable import Execa
import Foundation
import Testing

struct ScreenCaptureKitSourceTests {
    /// Permission-gated. Requires Screen Recording authorization for the test
    /// host. Exits early without failing if not authorized.
    @Test func capturesSystemAudioToWAV() async throws {
        guard CGPreflightScreenCaptureAccess() else { return }

        let dir = try MeetingsDirectory.url(forMeetingID: "sck-test-\(ULID.generate())")
        let url = dir.appendingPathComponent("system.wav")
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = ScreenCaptureKitSource()
        try await source.start(archivalURL: url)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        await source.stop()

        let file = try AVAudioFile(forReading: url)
        #expect(file.length > 0, "expected non-empty system.wav after 1 s of capture")
        #expect(file.fileFormat.sampleRate == 48000)
        #expect(file.fileFormat.channelCount == 1)
    }
}
