import AVFoundation
@testable import Execa
import Foundation
import GRDB
import Testing

/// BUG 6 regression gate, lives in its own file because the test body is
/// long enough to push `TranscriptionServiceTests` past SwiftLint's
/// type-body-length cap. Tests the back-to-back meetings invariant that
/// "Phase 2 was tested as one meeting end-to-end, never multi-meeting"
/// (per the user's lessons-learned note in BUILD_PLAN.md).
///
/// Failure mode being gated: Meeting 1's stop called
/// `tapHandler.close()` which finishes the source's `sttContinuation`
/// (a `let` set once at source init); Meeting 2's fresh tap handler
/// then yielded into the now-finished continuation and the chunks
/// silently disappeared. Audio capture itself worked
/// (`mic.wav` / `system.wav` populate correctly), but no transcription
/// reached Sarvam. Workaround was quit + relaunch.
struct BackToBackMeetingTests {
    private static func tempDB() throws -> Execa.Database {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("execa-b2b-\(UUID().uuidString).sqlite3")
        return try Execa.Database.make(at: url)
    }

    private static func makeSyntheticChunk() -> PCMChunk {
        PCMChunk(
            source: .mic,
            sampleRate: 16000,
            channelCount: 1,
            frameCount: 160,
            captureTime: Date(),
            samples: [Int16](repeating: 0, count: 160)
        )
    }

    @Test func backToBackMeetingsBothTranscribe() async throws {
        let database = try Self.tempDB()
        let permissions = PermissionsService()
        guard await permissions.microphoneStatus() == .authorized,
              permissions.screenRecordingStatus()
        else { return }

        let micStub = StubAudioSource()
        let systemStub = StubAudioSource()
        let audioCapture = AudioCaptureService(
            mic: micStub,
            system: systemStub,
            permissions: permissions,
            database: database
        )
        let store = await TranscriptStore(database: database)
        let service = TranscriptionService(store: store)

        let providers1 = MeetingMocks()
        let directory1 = try await Self.runMeeting(
            audioCapture: audioCapture,
            service: service,
            micStub: micStub,
            systemStub: systemStub,
            providerFactory: providers1.factory
        )
        defer { try? FileManager.default.removeItem(at: directory1) }
        #expect(providers1.mic.ingestedChunkCount() == 5, "Meeting 1 mic chunks should reach the first provider")
        #expect(providers1.system.ingestedChunkCount() == 5, "Meeting 1 system chunks should reach the first provider")

        let providers2 = MeetingMocks()
        let directory2 = try await Self.runMeeting(
            audioCapture: audioCapture,
            service: service,
            micStub: micStub,
            systemStub: systemStub,
            providerFactory: providers2.factory
        )
        defer { try? FileManager.default.removeItem(at: directory2) }

        #expect(
            providers2.mic.ingestedChunkCount() == 5,
            "BUG 6: Meeting 2 mic chunks must reach the new provider, got \(providers2.mic.ingestedChunkCount())"
        )
        #expect(
            providers2.system.ingestedChunkCount() == 5,
            "BUG 6: Meeting 2 system chunks must reach the new provider, got \(providers2.system.ingestedChunkCount())"
        )
    }

    /// Per-meeting bundle of `MockTranscriptionProvider`s plus the
    /// closure factory `TranscriptionService.start` expects.
    private struct MeetingMocks {
        let mic = MockTranscriptionProvider(events: [.connected])
        let system = MockTranscriptionProvider(events: [.connected])
        var factory: TranscriptionService.ProviderFactory {
            { [mic, system] source in
                switch source {
                case .mic: mic
                case .system: system
                }
            }
        }
    }

    /// Runs one start → 5-chunk emit → stop cycle. Returns the meeting
    /// directory so the caller can clean up.
    private static func runMeeting(
        audioCapture: AudioCaptureService,
        service: TranscriptionService,
        micStub: StubAudioSource,
        systemStub: StubAudioSource,
        providerFactory: TranscriptionService.ProviderFactory
    ) async throws -> URL {
        let meetingID = ULID.generate()
        let directory = try await audioCapture.start(meetingID: meetingID)
        try await service.start(
            providerFactory: providerFactory,
            context: TranscriptionService.StartContext(
                meetingID: meetingID,
                startedAt: Date(),
                displayName: "Anand",
                micStream: audioCapture.micSttStream,
                systemStream: audioCapture.systemSttStream
            )
        )
        let chunk = makeSyntheticChunk()
        for _ in 0 ..< 5 {
            micStub.emit(chunk)
            systemStub.emit(chunk)
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        await service.stop()
        _ = try await audioCapture.stop()
        return directory
    }
}
