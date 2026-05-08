import Foundation
import os

private let sarvamLogger = Logger(subsystem: "com.anandthakur.execa", category: "transcription.sarvam")

/// `TranscriptionProvider` for Sarvam's Saarika streaming Speech-to-Text.
///
/// Wire format established by the live discovery probe in commit 4
/// (see `DECISIONS.md` 2026-05-08 "Sarvam streaming API contract"):
/// - URL: `wss://api.sarvam.ai/speech-to-text/ws?language-code=...&model=...`
/// - Auth: `api-subscription-key: <key>` header on the upgrade request.
/// - Audio framing: JSON-wrapped base64,
///   `{"audio": {"data": "<b64>", "encoding": "audio/wav", "sample_rate": 16000}}`.
/// - Server messages: one `type: "data"` per VAD-detected utterance with a
///   complete transcript. **No interim/final distinction** — every message
///   carries a finalized chunk. We map these to `TranscriptionEvent.final`.
///
/// Reconnect: 5 attempts with exponential backoff (0.5 s, 1 s, 2 s, 4 s,
/// 8 s) per spec §4.2. After the 5th failure we emit
/// `.error(.reconnectExhausted)` and stop. The 30 s `AudioRingBuffer` is
/// drained into each new socket before live audio resumes so the user
/// doesn't lose what they said during the outage.
actor SarvamProvider: TranscriptionProvider {
    nonisolated let events: AsyncStream<TranscriptionEvent>
    private nonisolated let eventsContinuation: AsyncStream<TranscriptionEvent>.Continuation

    private let apiKey: String
    private let languageCode: String
    private let model: String
    private let ringBuffer: AudioRingBuffer

    private var session: URLSession?
    private var currentTask: URLSessionWebSocketTask?
    private var supervisorTask: Task<Void, Never>?
    private var producerTask: Task<Void, Never>?

    init(
        apiKey: String,
        languageCode: String = "en-IN",
        model: String = "saarika:v2.5",
        ringBuffer: AudioRingBuffer = AudioRingBuffer()
    ) {
        self.apiKey = apiKey
        self.languageCode = languageCode
        self.model = model
        self.ringBuffer = ringBuffer

        var capturedCont: AsyncStream<TranscriptionEvent>.Continuation?
        let stream = AsyncStream<TranscriptionEvent>(bufferingPolicy: .bufferingNewest(64)) { cont in
            capturedCont = cont
        }
        events = stream
        guard let cont = capturedCont else {
            preconditionFailure("AsyncStream did not yield continuation")
        }
        eventsContinuation = cont
    }

    func start(
        meetingID _: String,
        source: PCMChunk.Source,
        audioStream: AsyncStream<PCMChunk>
    ) async throws {
        sarvamLogger.info("starting (source=\(source.rawValue, privacy: .public))")
        producerTask = Task { [weak self] in
            await self?.runProducer(audioStream: audioStream)
        }
        supervisorTask = Task { [weak self] in
            await self?.runSupervisor()
        }
    }

    func stop() async {
        sarvamLogger.info("stopping")
        producerTask?.cancel()
        supervisorTask?.cancel()
        currentTask?.cancel(with: .normalClosure, reason: nil)
        producerTask = nil
        supervisorTask = nil
        currentTask = nil
        session = nil
        eventsContinuation.finish()
    }

    // MARK: - Producer (audio in)

    /// Reads upstream `PCMChunk`s and pushes them into the ring buffer
    /// AND, when a socket is connected, sends them straight to the wire.
    /// Always-on: keeps reading even during reconnect, so the ring captures
    /// the outage window.
    private func runProducer(audioStream: AsyncStream<PCMChunk>) async {
        for await chunk in audioStream {
            if Task.isCancelled { return }
            await ringBuffer.push(chunk)
            if let task = currentTask {
                try? await Self.send(chunk: chunk, on: task)
            }
        }
    }

    // MARK: - Supervisor (connect / receive / reconnect)

    private func runSupervisor() async {
        let maxAttempts = 5
        for attempt in 0 ... maxAttempts {
            if Task.isCancelled { return }
            if attempt > 0 {
                // Exponential backoff: 0.5 s, 1 s, 2 s, 4 s, 8 s.
                let exponent = Double(attempt - 1)
                let delaySeconds = 0.5 * pow(2.0, exponent)
                let delayNs = UInt64(delaySeconds * 1_000_000_000)
                sarvamLogger
                    .info("backing off \(delaySeconds, privacy: .public) s before retry #\(attempt, privacy: .public)")
                try? await Task.sleep(nanoseconds: delayNs)
                if Task.isCancelled { return }
            }
            do {
                let newTask = try connect()
                currentTask = newTask
                eventsContinuation.yield(.connected)
                // Drain the ring into the new socket before live audio
                // resumes from the producer.
                let backlog = await ringBuffer.drain()
                for chunk in backlog {
                    if Task.isCancelled { return }
                    try await Self.send(chunk: chunk, on: newTask)
                }
                try await runReceiver(task: newTask)
                // Receiver returned cleanly → external cancellation.
                return
            } catch {
                let description = String(describing: error)
                sarvamLogger.warning(
                    "connection attempt \(attempt, privacy: .public) failed: \(description, privacy: .public)"
                )
                eventsContinuation.yield(.disconnected)
                currentTask = nil
                if attempt == maxAttempts {
                    sarvamLogger.error("reconnect exhausted")
                    eventsContinuation.yield(.error(.reconnectExhausted))
                    return
                }
            }
        }
    }

    private func runReceiver(task: URLSessionWebSocketTask) async throws {
        while !Task.isCancelled {
            let message = try await task.receive()
            switch message {
            case let .string(text):
                if let event = Self.parseMessage(text) {
                    eventsContinuation.yield(event)
                }
            case .data:
                // Sarvam streaming doesn't emit binary frames in the
                // current contract; ignore defensively.
                continue
            @unknown default:
                continue
            }
        }
    }

    // MARK: - Wire helpers

    private func connect() throws -> URLSessionWebSocketTask {
        var components = URLComponents(string: "wss://api.sarvam.ai/speech-to-text/ws")
        components?.queryItems = [
            URLQueryItem(name: "language-code", value: languageCode),
            URLQueryItem(name: "model", value: model)
        ]
        guard let url = components?.url else {
            throw SarvamProviderError.invalidURL
        }
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "api-subscription-key")
        let session = URLSession(configuration: .default)
        self.session = session
        let task = session.webSocketTask(with: request)
        task.resume()
        return task
    }

    static func send(chunk: PCMChunk, on task: URLSessionWebSocketTask) async throws {
        let bytes = chunk.samples.withUnsafeBufferPointer { Data(buffer: $0) }
        let payload: [String: Any] = [
            "audio": [
                "data": bytes.base64EncodedString(),
                "encoding": "audio/wav",
                "sample_rate": Int(chunk.sampleRate)
            ]
        ]
        let json = try JSONSerialization.data(withJSONObject: payload)
        guard let str = String(data: json, encoding: .utf8) else {
            throw SarvamProviderError.encodingFailed
        }
        try await task.send(.string(str))
    }

    /// Parses one server message JSON string into a normalized
    /// `TranscriptionEvent`. Public-for-testing; called from
    /// `runReceiver` per inbound message. Returns nil for unrecognized or
    /// non-data message types so the receive loop can keep going.
    static func parseMessage(_ string: String) -> TranscriptionEvent? {
        guard let data = string.data(using: .utf8) else { return nil }
        do {
            let envelope = try JSONDecoder().decode(SarvamMessageEnvelope.self, from: data)
            guard envelope.type == "data", let payload = envelope.data else {
                return nil
            }
            let endMs = Int((payload.metrics?.audioDuration ?? 0) * 1000)
            let token = TranscriptToken(
                startMs: 0,
                endMs: endMs,
                speakerID: 0, // Sarvam streaming has no diarization (Path B).
                text: payload.transcript,
                confidence: nil,
                language: payload.languageCode
            )
            return .final(token)
        } catch {
            sarvamLogger.warning("parseMessage failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}

// MARK: - Wire types

enum SarvamProviderError: Error, Equatable {
    case invalidURL
    case encodingFailed
}

/// Decodable mirror of Sarvam's server message. Captured via the live
/// probe in commit 4. Fields we don't need (`timestamps`,
/// `diarized_transcript`, `language_probability`) are omitted from the
/// struct — Decodable ignores extra JSON keys.
struct SarvamMessageEnvelope: Decodable {
    let type: String
    let data: SarvamDataPayload?
}

struct SarvamDataPayload: Decodable {
    let requestId: String?
    let transcript: String
    let languageCode: String?
    let metrics: SarvamMetrics?

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case transcript
        case languageCode = "language_code"
        case metrics
    }
}

struct SarvamMetrics: Decodable {
    let audioDuration: Double?
    let processingLatency: Double?

    enum CodingKeys: String, CodingKey {
        case audioDuration = "audio_duration"
        case processingLatency = "processing_latency"
    }
}
