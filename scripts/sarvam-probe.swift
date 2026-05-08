#!/usr/bin/env swift
// Sarvam streaming STT discovery probe.
// Usage: swift scripts/sarvam-probe.swift [language-code] [model]
//   language-code default: en-IN
//   model         default: saarika:v2.5
//
// Reads the Sarvam API key from Keychain (com.anandthakur.execa.sarvam,
// account "default"), opens a WebSocket to Sarvam's streaming STT endpoint,
// streams Execa/ExecaTests/Fixtures/hello.wav as 100 ms base64-wrapped JSON
// chunks, prints every server message, and dumps a summary at the end.
//
// Used to capture real-wire fixtures for SarvamProvider's parser. Output is
// hand-saved to ExecaTests/Fixtures/*.json after each run (the script does
// NOT modify the repo). Re-run any time Sarvam changes their wire format.

import Foundation

// MARK: - Keychain

func readSarvamKey() -> String? {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.anandthakur.execa.sarvam",
        kSecAttrAccount as String: "default",
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne
    ]
    var item: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess, let data = item as? Data else { return nil }
    return String(data: data, encoding: .utf8)
}

guard let key = readSarvamKey() else {
    FileHandle.standardError.write(Data("""
    ERROR: No Sarvam key in Keychain. Add with:
      security add-generic-password -s com.anandthakur.execa.sarvam -a default -w '<KEY>' -U
    """.utf8))
    exit(1)
}
print("[probe] Loaded Sarvam key (\(key.count) chars).")

// MARK: - Inputs

let language = CommandLine.arguments.dropFirst().first ?? "en-IN"
let model = CommandLine.arguments.dropFirst().dropFirst().first ?? "saarika:v2.5"

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0])
let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let wavURL = repoRoot
    .appendingPathComponent("Execa", isDirectory: true)
    .appendingPathComponent("ExecaTests", isDirectory: true)
    .appendingPathComponent("Fixtures", isDirectory: true)
    .appendingPathComponent("hello.wav")
guard let wavData = try? Data(contentsOf: wavURL) else {
    FileHandle.standardError.write(Data("ERROR: could not read \(wavURL.path)\n".utf8))
    exit(1)
}
print("[probe] Loaded hello.wav (\(wavData.count) bytes) from \(wavURL.path).")

// MARK: - WebSocket

guard var components = URLComponents(string: "wss://api.sarvam.ai/speech-to-text/ws") else {
    FileHandle.standardError.write(Data("ERROR: bad URL.\n".utf8))
    exit(1)
}
components.queryItems = [
    URLQueryItem(name: "language-code", value: language),
    URLQueryItem(name: "model", value: model)
]
guard let url = components.url else {
    FileHandle.standardError.write(Data("ERROR: bad URLComponents.\n".utf8))
    exit(1)
}

var request = URLRequest(url: url)
request.setValue(key, forHTTPHeaderField: "api-subscription-key")
print("[probe] Connecting to \(url.absoluteString) …")

let session = URLSession(configuration: .default)
let task = session.webSocketTask(with: request)
task.resume()

// MARK: - Receiver task

actor ReceiveStore {
    private(set) var messages: [String] = []
    func append(_ message: String) { messages.append(message) }
}
let store = ReceiveStore()

let receiverTask = Task<Void, Never> {
    while !Task.isCancelled {
        do {
            let message = try await task.receive()
            switch message {
            case let .string(text):
                print("[recv] \(text)")
                await store.append(text)
            case let .data(data):
                print("[recv-binary] \(data.count) bytes")
            @unknown default:
                break
            }
        } catch {
            print("[recv-error] \(error)")
            break
        }
    }
}

// MARK: - WAV header parsing

func extractPCM(from wav: Data) -> Data? {
    // RIFF<size>WAVE then a series of chunks; find "data".
    guard wav.count >= 12,
          wav.subdata(in: 0 ..< 4) == Data("RIFF".utf8),
          wav.subdata(in: 8 ..< 12) == Data("WAVE".utf8)
    else {
        return nil
    }
    var offset = 12
    while offset + 8 <= wav.count {
        let chunkID = wav.subdata(in: offset ..< offset + 4)
        let sizeBytes = wav.subdata(in: offset + 4 ..< offset + 8)
        let size = Int(sizeBytes.withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian)
        let payloadStart = offset + 8
        let payloadEnd = payloadStart + size
        if chunkID == Data("data".utf8) {
            guard payloadEnd <= wav.count else { return nil }
            return wav.subdata(in: payloadStart ..< payloadEnd)
        }
        // Pad to even-byte alignment per RIFF spec.
        offset = payloadEnd + (size & 1)
    }
    return nil
}

// MARK: - Send audio in 100 ms chunks

func sendAudio() async throws {
    let sampleRate = 16000
    let chunkBytes = sampleRate * 2 / 10 // 100 ms @ 16 kHz Int16 mono = 3200 bytes
    guard let speech = extractPCM(from: wavData) else {
        FileHandle.standardError.write(Data("ERROR: could not parse WAV data chunk.\n".utf8))
        return
    }
    // Pad with 2 s of silence so Sarvam's VAD sees an end-of-speech.
    var pcm = speech
    pcm.append(Data(repeating: 0, count: 2 * sampleRate * 2))
    print("[probe] PCM payload: \(pcm.count) bytes (\(Double(pcm.count) / 32000.0) s @ 16 kHz, including 2 s trailing silence)")
    var offset = 0
    while offset < pcm.count {
        let end = min(offset + chunkBytes, pcm.count)
        let chunk = pcm.subdata(in: offset ..< end)
        let payload: [String: Any] = [
            "audio": [
                "data": chunk.base64EncodedString(),
                "encoding": "audio/wav",
                "sample_rate": sampleRate
            ]
        ]
        let json = try JSONSerialization.data(withJSONObject: payload)
        guard let str = String(data: json, encoding: .utf8) else { break }
        try await task.send(.string(str))
        offset = end
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    print("[probe] All audio chunks sent. Waiting 5 s for trailing server messages…")
    try await Task.sleep(nanoseconds: 5_000_000_000)
}

// Give the task a moment to upgrade before we start sending.
try? await Task.sleep(nanoseconds: 1_000_000_000)
print("[probe] After 1 s pause: task.state=\(task.state.rawValue) closeCode=\(task.closeCode.rawValue)")

do {
    try await sendAudio()
} catch {
    print("[send-error] \(error)")
}
print("[probe] Post-send: task.state=\(task.state.rawValue) closeCode=\(task.closeCode.rawValue) closeReason=\(String(describing: task.closeReason))")

// MARK: - Wrap up

task.cancel(with: .normalClosure, reason: nil)
try? await Task.sleep(nanoseconds: 500_000_000)
receiverTask.cancel()
let messages = await store.messages

print("\n[probe] --- SUMMARY ---")
print("[probe] Received \(messages.count) message(s).")
for (index, msg) in messages.enumerated() {
    print("[probe] Message \(index + 1): \(msg)")
}
