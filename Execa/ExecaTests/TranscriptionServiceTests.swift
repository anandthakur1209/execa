@testable import Execa
import Foundation
import GRDB
import Testing

/// `.serialized` because two of these tests
/// (`missingSarvamKeyHardRefusesToStartMeeting`,
/// `dismissingMissingSTTKeyErrorReturnsToIdle`) wipe and restore the
/// real Sarvam keychain entry. Without serialisation, parallel test
/// execution within this suite — and against other suites that read
/// the same key — produces wildly inconsistent results: a second test's
/// `defer` can restore the key while a first test is still asserting
/// it's gone, etc. Serialising within the suite isn't a complete fix
/// (other suites can still race), but the only other keychain reader
/// is `SarvamProviderIntegrationTests` which fails-soft (skips if no
/// key), so per-suite serialisation suffices in practice.
@Suite(.serialized)
struct TranscriptionServiceTests {
    private static func tempDB() throws -> Execa.Database {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("execa-tx-\(UUID().uuidString).sqlite3")
        return try Execa.Database.make(at: url)
    }

    private static func token(
        speakerID: Int = 0,
        text: String,
        startMs: Int = 0,
        endMs: Int = 1000
    ) -> TranscriptToken {
        TranscriptToken(
            startMs: startMs,
            endMs: endMs,
            speakerID: speakerID,
            text: text,
            confidence: 0.9,
            language: nil
        )
    }

    private static func insertMeetingRow(_ database: Execa.Database, id: String) async throws {
        try await database.queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO meetings (id, title, started_at, status)
                VALUES (?, NULL, ?, 'live')
                """,
                arguments: [id, Int64(Date().timeIntervalSince1970 * 1000)]
            )
        }
    }

    private static func transcriptSegmentTexts(
        _ database: Execa.Database,
        meetingID: String
    ) async throws -> [String] {
        try await database.queue.read { db -> [String] in
            try Row.fetchAll(
                db,
                sql: """
                SELECT text FROM transcript_segments
                WHERE meeting_id = ? ORDER BY id ASC
                """,
                arguments: [meetingID]
            ).map { $0["text"] }
        }
    }

    @Test func startBridgesEventsIntoStore() async throws {
        let database = try Self.tempDB()
        let meetingID = ULID.generate()
        try await Self.insertMeetingRow(database, id: meetingID)

        let store = await TranscriptStore(database: database)
        let service = TranscriptionService(store: store)
        let factoryFn = Self.makeFactoryWithThreeFinals()

        let (micStream, micCont) = AsyncStream<PCMChunk>.makeStream()
        let (systemStream, systemCont) = AsyncStream<PCMChunk>.makeStream()
        let context = TranscriptionService.StartContext(
            meetingID: meetingID,
            startedAt: Date(),
            displayName: "Anand",
            micStream: micStream,
            systemStream: systemStream
        )

        try await service.start(providerFactory: factoryFn, context: context)
        // 2 s headroom for both bridge tasks to drain three events apiece
        // and commit their DB writes. 500 ms was tight under
        // `.serialized` suite load + parallel suite execution; bumped
        // here rather than racing the wall clock.
        try await Task.sleep(nanoseconds: 2_000_000_000)

        try await assertThreeFinalsLanded(database: database, meetingID: meetingID)

        await service.stop()
        micCont.finish()
        systemCont.finish()
    }

    /// One mic final + two system finals (with diarized speaker IDs 0 and 1).
    /// Used by `startBridgesEventsIntoStore` and shared with any future
    /// "happy path" test variants.
    private static func makeFactoryWithThreeFinals() -> TranscriptionService.ProviderFactory {
        let micEvents: [TranscriptionEvent] = [
            .connected,
            .interim(Self.token(text: "hel...")),
            .final(Self.token(text: "hello world"))
        ]
        let systemEvents: [TranscriptionEvent] = [
            .connected,
            .final(Self.token(speakerID: 0, text: "remote one")),
            .final(Self.token(speakerID: 1, text: "remote two"))
        ]
        return { source in
            switch source {
            case .mic: MockTranscriptionProvider(events: micEvents)
            case .system: MockTranscriptionProvider(events: systemEvents)
            }
        }
    }

    private func assertThreeFinalsLanded(database: Execa.Database, meetingID: String) async throws {
        let rowCount = try await database.queue.read { db -> Int in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM transcript_segments WHERE meeting_id = ?",
                arguments: [meetingID]
            ) ?? 0
        }
        #expect(rowCount == 3, "expected 3 final segments, got \(rowCount)")

        let labels = try await database.queue.read { db -> [String] in
            try Row.fetchAll(
                db,
                sql: """
                SELECT s.display_label FROM transcript_segments t
                JOIN speakers s ON s.id = t.speaker_id
                WHERE t.meeting_id = ? ORDER BY t.id ASC
                """,
                arguments: [meetingID]
            ).map { $0["display_label"] }
        }
        // Order isn't strictly defined across concurrent mic/system bridges,
        // but the multiset must match. The system stream delivers
        // speaker_id 0 and 1; under the Path-B label policy that's
        // ("Remote", "Speaker 2") rather than ("Speaker 1", "Speaker 2").
        // Mic delivers speaker_id 0 only → displayName.
        #expect(Set(labels) == Set(["Anand", "Remote", "Speaker 2"]), "labels were \(labels)")
    }

    @Test func stopFlushesPendingInterim() async throws {
        let database = try Self.tempDB()
        let meetingID = ULID.generate()
        try await Self.insertMeetingRow(database, id: meetingID)

        let store = await TranscriptStore(database: database)
        let service = TranscriptionService(store: store)

        // Mic stream emits a connected + interim, but no final. System
        // stream is silent.
        let micEvents: [TranscriptionEvent] = [
            .connected,
            .interim(Self.token(text: "the last word was lost..."))
        ]
        let factoryFn: TranscriptionService.ProviderFactory = { source in
            switch source {
            case .mic: MockTranscriptionProvider(events: micEvents)
            case .system: MockTranscriptionProvider(events: [])
            }
        }

        let (micStream, micCont) = AsyncStream<PCMChunk>.makeStream()
        let (systemStream, systemCont) = AsyncStream<PCMChunk>.makeStream()
        let context = TranscriptionService.StartContext(
            meetingID: meetingID,
            startedAt: Date(),
            displayName: "Anand",
            micStream: micStream,
            systemStream: systemStream
        )

        try await service.start(providerFactory: factoryFn, context: context)
        try await Task.sleep(nanoseconds: 50_000_000)
        await service.stop()
        // service.stop() schedules flush as fire-and-forget under MainActor.
        // Give it a moment to write before we assert.
        try await Task.sleep(nanoseconds: 100_000_000)

        let rowCount = try await database.queue.read { db -> Int in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM transcript_segments WHERE meeting_id = ?",
                arguments: [meetingID]
            ) ?? 0
        }
        #expect(rowCount == 1, "stop should flush pending interim into a final row, got \(rowCount)")

        micCont.finish()
        systemCont.finish()
    }

    @Test func retryEmitsAdditionalEventsWithoutClearingTranscript() async throws {
        // BUG 5 regression gate: when a provider exhausts reconnect
        // retries and emits .error(.reconnectExhausted),
        // TranscriptionService.retry() must restart the same provider's
        // connection logic. Subsequent events (post-retry) must commit
        // fresh transcript_segments rows ON TOP OF the existing ones —
        // not reset the store.
        let database = try Self.tempDB()
        let meetingID = ULID.generate()
        try await Self.insertMeetingRow(database, id: meetingID)

        let store = await TranscriptStore(database: database)
        let service = TranscriptionService(store: store)
        let (micStream, _) = AsyncStream<PCMChunk>.makeStream()
        let (systemStream, _) = AsyncStream<PCMChunk>.makeStream()
        let context = TranscriptionService.StartContext(
            meetingID: meetingID,
            startedAt: Date(),
            displayName: "Anand",
            micStream: micStream,
            systemStream: systemStream
        )

        // Scripted mocks with both pre-exhaustion AND post-retry events.
        // The retry() call drains the eventsAfterRetry array into the
        // SAME events stream — same provider instance, same bridge
        // task, no new provider construction.
        let micMock = MockTranscriptionProvider(
            events: [
                .connected,
                .final(Self.token(text: "first turn before outage")),
                .error(.reconnectExhausted)
            ],
            eventsAfterRetry: [
                .connected,
                .final(Self.token(text: "second turn after retry"))
            ]
        )
        let systemMock = MockTranscriptionProvider(events: [.connected])
        let factory: TranscriptionService.ProviderFactory = { source in
            switch source {
            case .mic: micMock
            case .system: systemMock
            }
        }

        try await service.start(providerFactory: factory, context: context)
        try await Task.sleep(nanoseconds: 500_000_000)

        let baselineRows = try await Self.transcriptSegmentTexts(database, meetingID: meetingID)
        #expect(baselineRows == ["first turn before outage"], "phase 1 rows were \(baselineRows)")
        #expect(await store.connection[.mic] == .stopped)

        await service.retry()
        try await Task.sleep(nanoseconds: 500_000_000)

        let postRetryRows = try await Self.transcriptSegmentTexts(database, meetingID: meetingID)
        #expect(
            postRetryRows == ["first turn before outage", "second turn after retry"],
            "expected retry to append, not reset; got \(postRetryRows)"
        )
        #expect(await store.connection[.mic] == .connected)

        await service.stop()
    }

    /// BUG 4 regression gate: when the missing-Sarvam-key gate trips and
    /// the audioCapture state is `.error(.missingSTTKey)`,
    /// `coordinator.dismissError()` must return the state to `.idle`. The
    /// previous Dismiss button routed through `startMeeting()`, which
    /// re-tripped the same preflight error and left the user visibly
    /// stuck. Lives here (not `AppCoordinatorTests`) because of the
    /// keychain-mutation pattern — keeps all wipe-then-restore tests in
    /// one `.serialized` suite.
    @Test func dismissingMissingSTTKeyErrorReturnsToIdle() async throws {
        let keychain = KeychainStore()
        let service = KeychainStore.serviceName(forProvider: "sarvam")
        let savedKey = (try? keychain.get(service: service, account: "default")) ?? nil
        try? keychain.delete(service: service, account: "default")
        defer {
            if let savedKey {
                try? keychain.set(savedKey, service: service, account: "default")
            }
        }

        let coordinator = try await AppCoordinator()
        await #expect(throws: MeetingError.self) {
            try await coordinator.startMeeting()
        }

        let errorState = await coordinator.audioCapture.state
        guard case .error(.missingSTTKey) = errorState else {
            Issue.record("expected .error(.missingSTTKey); got \(errorState)")
            return
        }

        await coordinator.dismissError()

        let postDismissState = await coordinator.audioCapture.state
        if case .idle = postDismissState {
            // ok
        } else {
            Issue.record("expected .idle after dismissError(); got \(postDismissState)")
        }
    }

    @Test func missingSarvamKeyHardRefusesToStartMeeting() async throws {
        // Wipe any pre-existing entry from the dev machine's Keychain so the
        // gate fires. (We restore it at end.)
        let keychain = KeychainStore()
        let service = KeychainStore.serviceName(forProvider: "sarvam")
        let prior = try? keychain.get(service: service, account: "default")
        try? keychain.delete(service: service, account: "default")
        defer {
            if let prior {
                try? keychain.set(prior, service: service, account: "default")
            }
        }

        let coordinator = try await AppCoordinator()

        await #expect(throws: MeetingError.self) {
            try await coordinator.startMeeting()
        }

        // The error state must have surfaced via audioCapture.state so the
        // menu bar can render it.
        var sawMissingKey = false
        let stream = await coordinator.audioCapture.stateStream
        for await state in stream {
            if case .error(.missingSTTKey) = state {
                sawMissingKey = true
                break
            }
            // Avoid hanging the test if the state never transitions.
            if case .idle = state { continue }
            break
        }
        #expect(sawMissingKey, "expected MeetingState.error(.missingSTTKey) on the state stream")
    }
}
