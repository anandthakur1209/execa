@testable import Execa
import Foundation
import GRDB
import Testing

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
        // 500 ms is enough headroom for both bridge tasks to drain three
        // events apiece and complete their DB writes; 100 ms was racy.
        try await Task.sleep(nanoseconds: 500_000_000)

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

    @Test func resumeAttachesNewProvidersWithoutClearingTranscript() async throws {
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

        try await service.start(
            providerFactory: Self.factoryWithMic(["first turn before outage"], terminating: true),
            context: context
        )
        try await Task.sleep(nanoseconds: 200_000_000)
        try await Self.assertResumeBaseline(database: database, meetingID: meetingID, store: store)

        try await service.resume(
            providerFactory: Self.factoryWithMic(["second turn after resume"], terminating: false),
            context: context
        )
        try await Task.sleep(nanoseconds: 200_000_000)
        try await Self.assertResumeAppended(database: database, meetingID: meetingID, store: store)

        await service.stop()
    }

    // MARK: - Resume-test helpers

    /// Builds a factory that returns mocks scripted to emit one .final
    /// per text plus an optional terminating .error(.reconnectExhausted)
    /// on mic. System always emits just .connected.
    private static func factoryWithMic(
        _ texts: [String],
        terminating: Bool
    ) -> TranscriptionService.ProviderFactory {
        var micEvents: [TranscriptionEvent] = [.connected]
        for text in texts {
            micEvents.append(.final(Self.token(text: text)))
        }
        if terminating {
            micEvents.append(.error(.reconnectExhausted))
        }
        let micRef = MockTranscriptionProvider(events: micEvents)
        let systemRef = MockTranscriptionProvider(events: [.connected])
        return { source in
            switch source {
            case .mic: micRef
            case .system: systemRef
            }
        }
    }

    private static func assertResumeBaseline(
        database: Execa.Database,
        meetingID: String,
        store: TranscriptStore
    ) async throws {
        let rows = try await transcriptSegmentTexts(database, meetingID: meetingID)
        #expect(rows == ["first turn before outage"], "phase 1 rows were \(rows)")
        #expect(await store.connection[.mic] == .stopped)
    }

    private static func assertResumeAppended(
        database: Execa.Database,
        meetingID: String,
        store: TranscriptStore
    ) async throws {
        let rows = try await transcriptSegmentTexts(database, meetingID: meetingID)
        #expect(
            rows == ["first turn before outage", "second turn after resume"],
            "expected resume to append, not reset; got \(rows)"
        )
        #expect(await store.connection[.mic] == .connected)
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
