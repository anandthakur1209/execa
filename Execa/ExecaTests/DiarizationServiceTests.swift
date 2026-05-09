@testable import Execa
import Foundation
import GRDB
import Testing

/// DB-driven tests for `DiarizationService`. Uses an in-process mock
/// `diarize` closure so the live Sarvam endpoint isn't hit; the
/// real-API integration is covered by `SarvamBatchClientIntegrationTests`.
///
/// Plan-mandated coverage (Phase 3 commit 4) split across two structs
/// to stay under the type-body-length cap:
///   - `DiarizationServiceHappyPathTests` covers the success swap and
///     the cross-source data flow.
///   - `DiarizationServiceEdgeCaseTests` covers empty meeting, batch
///     failure, single-speaker results, and the mic-rename
///     preservation rule (Decision 17).
struct DiarizationServiceHappyPathTests {
    @Test func happyPathSwapsBothSourcesAndFlipsStatus() async throws {
        let env = try await DiarizationTestEnv.make(displayName: "Anand")
        try await env.seedStreaming(source: "mic", rawSpeakerID: 0, label: "Anand", text: "stream-mic")
        try await env.seedStreaming(source: "system", rawSpeakerID: 0, label: "Remote", text: "stream-system")

        await env.run(
            mic: .success(SarvamBatchResult(segments: [
                .init(speakerID: 0, startMs: 0, endMs: 1500, text: "hello mic 0", languageCode: "en-IN"),
                .init(speakerID: 1, startMs: 1500, endMs: 2500, text: "hello mic 1", languageCode: "en-IN")
            ])),
            system: .success(SarvamBatchResult(segments: [
                .init(speakerID: 0, startMs: 0, endMs: 1000, text: "system 0", languageCode: "en-IN")
            ]))
        )

        let speakers = try await env.allSpeakers()
        try #require(speakers.count == 3, "expected 3 swap rows, got \(speakers)")
        #expect(speakers[0] == ["mic", "0", "Anand"])
        #expect(speakers[1] == ["mic", "1", "In-room 2"])
        #expect(speakers[2] == ["system", "0", "Speaker 1"])

        let texts = try await env.segmentTexts()
        #expect(texts.contains("hello mic 0"))
        #expect(texts.contains("hello mic 1"))
        #expect(texts.contains("system 0"))
        #expect(!texts.contains("stream-mic"))
        #expect(!texts.contains("stream-system"))

        #expect(try await env.persistedStatus() == "ok")
        try await env.expectStoreCompleted()
    }

    @Test func bothSourcesLandIndependentSpeakers() async throws {
        let env = try await DiarizationTestEnv.make(displayName: "You")
        try await env.seedStreaming(source: "mic", rawSpeakerID: 0, label: "You", text: "s-mic")
        try await env.seedStreaming(source: "system", rawSpeakerID: 0, label: "Remote", text: "s-sys")

        await env.run(
            mic: .success(SarvamBatchResult(segments: [
                .init(speakerID: 0, startMs: 0, endMs: 1000, text: "user", languageCode: "en-IN"),
                .init(speakerID: 1, startMs: 1000, endMs: 2000, text: "in-room", languageCode: "en-IN")
            ])),
            system: .success(SarvamBatchResult(segments: [
                .init(speakerID: 0, startMs: 0, endMs: 800, text: "remote 1", languageCode: "en-IN"),
                .init(speakerID: 1, startMs: 800, endMs: 1600, text: "remote 2", languageCode: "en-IN"),
                .init(speakerID: 2, startMs: 1600, endMs: 2400, text: "remote 3", languageCode: "en-IN")
            ]))
        )

        let labels = try await env.allLabels()
        #expect(labels == ["You", "In-room 2", "Speaker 1", "Speaker 2", "Speaker 3"])
        #expect(try await env.segmentCount() == 5)
    }
}

struct DiarizationServiceEdgeCaseTests {
    @Test func emptyMeetingDoesNotFireBatchAndKeepsStatusUntouched() async throws {
        let env = try await DiarizationTestEnv.make(displayName: nil)
        let counter = CallCounter()
        await env.runWithCounter(counter: counter)

        #expect(await counter.count == 0, "empty meeting should skip the batch entirely")
        #expect(try await env.persistedStatus() == nil)
        #expect(await env.statusStore.status(forMeetingID: env.meetingID) == .notRequested)
    }

    @Test func batchFailureLeavesPreBatchRowsAndFlipsStatusToFailed() async throws {
        let env = try await DiarizationTestEnv.make(displayName: nil)
        try await env.seedStreaming(source: "mic", rawSpeakerID: 0, label: "You", text: "stream-text")

        await env.run(
            mic: .failure(DiarizationTestEnv.MockError.simulatedFailure),
            system: .success(SarvamBatchResult(segments: []))
        )

        #expect(try await env.segmentCount() == 1, "transcript_segments untouched on batch failure")
        let firstText = try await env.segmentTexts().first
        #expect(firstText == "stream-text")
        #expect(try await env.persistedStatus() == "failed")
        try await env.expectStoreFailed()
    }

    @Test func singleSpeakerResultReplacesCollapsedLabelCleanly() async throws {
        let env = try await DiarizationTestEnv.make(displayName: nil)
        try await env.seedStreaming(source: "mic", rawSpeakerID: 0, label: "You", text: "stream-mic")

        await env.run(
            mic: .success(SarvamBatchResult(segments: [
                .init(speakerID: 0, startMs: 0, endMs: 2000, text: "single", languageCode: "en-IN")
            ])),
            system: .success(SarvamBatchResult(segments: []))
        )

        #expect(try await env.speakerCount() == 1)
        let firstText = try await env.segmentTexts().first
        #expect(firstText == "single")
    }

    @Test func micZeroRenamePreservedAcrossSwap() async throws {
        let env = try await DiarizationTestEnv.make(displayName: "Anand")
        try await env.seedStreaming(
            source: "mic", rawSpeakerID: 0,
            label: "Anand-renamed", text: "stream-mic"
        )

        await env.run(
            mic: .success(SarvamBatchResult(segments: [
                .init(speakerID: 0, startMs: 0, endMs: 1000, text: "user", languageCode: "en-IN"),
                .init(speakerID: 1, startMs: 1000, endMs: 2000, text: "in-room", languageCode: "en-IN")
            ])),
            system: .success(SarvamBatchResult(segments: []))
        )

        #expect(try await env.label(source: "mic", rawSpeakerID: 0) == "Anand-renamed")
        #expect(try await env.label(source: "mic", rawSpeakerID: 1) == "In-room 2")
    }

    @Test func micZeroDefaultLabelDoesNotOverridePathBSwap() async throws {
        // If the user never renamed mic-0 mid-meeting, the streaming
        // label is exactly displayName. The swap should write the
        // displayName value back rather than special-case "preserving"
        // an identical value — verifies the
        // "captured-only-if-different" guard.
        let env = try await DiarizationTestEnv.make(displayName: "Maya")
        try await env.seedStreaming(source: "mic", rawSpeakerID: 0, label: "Maya", text: "s")

        await env.run(
            mic: .success(SarvamBatchResult(segments: [
                .init(speakerID: 0, startMs: 0, endMs: 1000, text: "x", languageCode: "en-IN")
            ])),
            system: .success(SarvamBatchResult(segments: []))
        )
        #expect(try await env.label(source: "mic", rawSpeakerID: 0) == "Maya")
    }
}

// MARK: - Test environment

/// Bundles the per-test `Database`, `SettingsStore`,
/// `DiarizationStatusStore`, and meeting-row setup so each `@Test`
/// reads as a sequence of intent (seed → run → assert) without DB
/// boilerplate. `MainActor`-isolated because the status store is
/// `@MainActor`.
@MainActor
final class DiarizationTestEnv {
    let database: Execa.Database
    let settings: SettingsStore
    let statusStore: DiarizationStatusStore
    let meetingID: String

    private init(database: Execa.Database, settings: SettingsStore, meetingID: String) async {
        self.database = database
        self.settings = settings
        statusStore = DiarizationStatusStore()
        self.meetingID = meetingID
    }

    static func make(displayName: String?, meetingID: String = "m1") async throws -> DiarizationTestEnv {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("execa-diar-svc-\(UUID().uuidString).sqlite3")
        let database = try Execa.Database.make(at: url)
        let settings = SettingsStore(database: database)
        if let displayName {
            try await settings.setString(displayName, forKey: .displayName)
        }
        try await database.queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO meetings (id, title, started_at, status)
                VALUES (?, NULL, ?, 'ended')
                """,
                arguments: [meetingID, Int64(Date().timeIntervalSince1970 * 1000)]
            )
        }
        return await DiarizationTestEnv(database: database, settings: settings, meetingID: meetingID)
    }

    enum MockError: Error, Equatable {
        case simulatedFailure
        case unexpectedFile(String)
    }

    /// Inserts a streaming-time speaker (collapsed label) + one
    /// segment so the swap has something to replace.
    func seedStreaming(source: String, rawSpeakerID: Int, label: String, text: String) async throws {
        try await database.queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO speakers (meeting_id, source, raw_speaker_id, display_label)
                VALUES (?, ?, ?, ?)
                """,
                arguments: [self.meetingID, source, rawSpeakerID, label]
            )
            let speakerRowID = db.lastInsertedRowID
            try db.execute(
                sql: """
                INSERT INTO transcript_segments
                    (meeting_id, speaker_id, start_ms, end_ms, text, is_final, confidence)
                VALUES (?, ?, 0, 1000, ?, 1, NULL)
                """,
                arguments: [self.meetingID, speakerRowID, text]
            )
        }
    }

    /// Builds a `DiarizationService` with a mock diarize closure that
    /// routes by filename, then runs it on `mic.wav` / `system.wav`.
    func run(
        mic: Result<SarvamBatchResult, Error>,
        system: Result<SarvamBatchResult, Error>
    ) async {
        let service = DiarizationService(
            database: database,
            statusStore: statusStore,
            settings: settings,
            diarize: { @Sendable wavURL, _ in
                switch wavURL.lastPathComponent {
                case "mic.wav": return try mic.get()
                case "system.wav": return try system.get()
                default: throw MockError.unexpectedFile(wavURL.lastPathComponent)
                }
            }
        )
        await service.runForMeeting(
            meetingID: meetingID,
            micWAV: URL(fileURLWithPath: "/tmp/execa-mock/mic.wav"),
            systemWAV: URL(fileURLWithPath: "/tmp/execa-mock/system.wav")
        )
    }

    /// Variant that lets a test count how many times the diarize
    /// closure fires (used to verify the empty-meeting skip path).
    func runWithCounter(counter: CallCounter) async {
        let service = DiarizationService(
            database: database,
            statusStore: statusStore,
            settings: settings,
            diarize: { @Sendable _, _ in
                await counter.increment()
                return SarvamBatchResult(segments: [])
            }
        )
        await service.runForMeeting(
            meetingID: meetingID,
            micWAV: URL(fileURLWithPath: "/tmp/execa-mock/mic.wav"),
            systemWAV: URL(fileURLWithPath: "/tmp/execa-mock/system.wav")
        )
    }

    // MARK: - Assertions

    /// `[(source, raw_speaker_id, label)]` rows in deterministic
    /// `(source, raw_speaker_id)` order.
    func allSpeakers() async throws -> [[String]] {
        try await database.queue.read { db -> [[String]] in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT source, raw_speaker_id, display_label FROM speakers
                WHERE meeting_id = ?
                ORDER BY source, raw_speaker_id
                """,
                arguments: [self.meetingID]
            )
            return rows.map { [
                $0["source"] as String,
                String($0["raw_speaker_id"] as Int),
                $0["display_label"] as String
            ] }
        }
    }

    func allLabels() async throws -> [String] {
        try await database.queue.read { db in
            try String.fetchAll(
                db,
                sql: """
                SELECT display_label FROM speakers
                WHERE meeting_id = ?
                ORDER BY source, raw_speaker_id
                """,
                arguments: [self.meetingID]
            )
        }
    }

    func segmentTexts() async throws -> [String] {
        try await database.queue.read { db in
            try String.fetchAll(
                db,
                sql: """
                SELECT text FROM transcript_segments
                WHERE meeting_id = ? ORDER BY start_ms
                """,
                arguments: [self.meetingID]
            )
        }
    }

    func segmentCount() async throws -> Int {
        try await database.queue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM transcript_segments WHERE meeting_id = ?",
                arguments: [self.meetingID]
            ) ?? 0
        }
    }

    func speakerCount() async throws -> Int {
        try await database.queue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM speakers WHERE meeting_id = ?",
                arguments: [self.meetingID]
            ) ?? 0
        }
    }

    func label(source: String, rawSpeakerID: Int) async throws -> String? {
        try await database.queue.read { db in
            try String.fetchOne(
                db,
                sql: """
                SELECT display_label FROM speakers
                WHERE meeting_id = ? AND source = ? AND raw_speaker_id = ?
                """,
                arguments: [self.meetingID, source, rawSpeakerID]
            )
        }
    }

    func persistedStatus() async throws -> String? {
        try await database.queue.read { db -> String? in
            try String.fetchOne(
                db,
                sql: "SELECT diarization_status FROM meetings WHERE id = ?",
                arguments: [self.meetingID]
            )
        }
    }

    func expectStoreCompleted() throws {
        let status = statusStore.status(forMeetingID: meetingID)
        if case .completed = status { return }
        Issue.record("expected store status .completed, got \(status)")
    }

    func expectStoreFailed() throws {
        let status = statusStore.status(forMeetingID: meetingID)
        if case .failed = status { return }
        Issue.record("expected store status .failed, got \(status)")
    }
}

/// Plain actor-based counter for the empty-meeting skip-test.
actor CallCounter {
    private var current = 0
    var count: Int {
        current
    }

    func increment() {
        current += 1
    }
}
