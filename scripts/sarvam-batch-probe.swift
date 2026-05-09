#!/usr/bin/env swift
// Sarvam batch STT discovery probe (with diarization).
// Usage: swift scripts/sarvam-batch-probe.swift [language-code] [model]
//   language-code default: en-IN
//   model         default: saarika:v2.5
//
// Reads the Sarvam API key from Keychain (com.anandthakur.execa.sarvam,
// account "default"), runs the full Sarvam batch STT job lifecycle on
// Execa/ExecaTests/Fixtures/hello.wav with `with_diarization=true`,
// prints raw responses, and writes the final transcript JSON to
// Execa/ExecaTests/Fixtures/sarvam-batch-result-sample.json.
//
// The lifecycle is six steps (companion to the Phase 2 streaming probe):
//   1. POST /speech-to-text/job/v1                      — init job
//   2. POST /speech-to-text/job/v1/upload-files         — get presigned URLs
//   3. PUT each presigned URL                           — upload audio
//   4. POST /speech-to-text/job/v1/{id}/start           — start processing
//   5. GET  /speech-to-text/job/v1/{id}/status (poll)   — wait for Completed
//   6. POST /speech-to-text/job/v1/download-files       — get result URLs
//      then GET each presigned download URL            — fetch transcript
//
// Used to capture the wire fixture for SarvamBatchClient + lock the
// endpoint paths / request shapes / response JSON in DECISIONS.md.
// Re-run any time Sarvam changes the batch contract.

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

let language = CommandLine.arguments.dropFirst().first ?? "en-IN"
let model = CommandLine.arguments.dropFirst().dropFirst().first ?? "saarika:v2.5"

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0])
let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let fixturesDir = repoRoot
    .appendingPathComponent("Execa", isDirectory: true)
    .appendingPathComponent("ExecaTests", isDirectory: true)
    .appendingPathComponent("Fixtures", isDirectory: true)
let wavURL = fixturesDir.appendingPathComponent("hello.wav")
let resultFixtureURL = fixturesDir.appendingPathComponent("sarvam-batch-result-sample.json")

guard let wavData = try? Data(contentsOf: wavURL) else {
    FileHandle.standardError.write(Data("ERROR: could not read \(wavURL.path)\n".utf8))
    exit(1)
}
print("[probe] Loaded hello.wav (\(wavData.count) bytes) from \(wavURL.path).")

// MARK: - JSON POST helper

func postJSON(endpoint: String, json: [String: Any]) async -> (Int, Data?) {
    print("\n[probe] === POST \(endpoint) ===")
    let pretty = (try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted)).flatMap {
        String(data: $0, encoding: .utf8)
    } ?? "<unencodable>"
    print("[probe] Body: \(pretty)")

    guard let url = URL(string: endpoint) else {
        print("[probe] Bad URL: \(endpoint)")
        return (-1, nil)
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue(key, forHTTPHeaderField: "api-subscription-key")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: json)

    do {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        print("[probe] HTTP \(status)")
        if let s = String(data: data, encoding: .utf8) {
            print("[probe] Body: \(s)")
        } else {
            print("[probe] Body (\(data.count) bytes, non-utf8)")
        }
        return (status, data)
    } catch {
        print("[probe] ERROR: \(error)")
        return (-1, nil)
    }
}

// MARK: - PUT helper (for presigned upload + raw blob downloads)

func putBlob(url: String, data: Data, contentType: String, isAzureBlob: Bool) async -> Int {
    print("\n[probe] === PUT \(url.prefix(120))... ===")
    guard let target = URL(string: url) else {
        print("[probe] Bad URL")
        return -1
    }
    var request = URLRequest(url: target)
    request.httpMethod = "PUT"
    request.setValue(contentType, forHTTPHeaderField: "Content-Type")
    if isAzureBlob {
        request.setValue("BlockBlob", forHTTPHeaderField: "x-ms-blob-type")
    }
    request.httpBody = data
    do {
        let (respData, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        print("[probe] HTTP \(status)")
        if !respData.isEmpty, let s = String(data: respData, encoding: .utf8) {
            print("[probe] Body: \(s)")
        }
        return status
    } catch {
        print("[probe] ERROR: \(error)")
        return -1
    }
}

// MARK: - GET helper

func getURL(_ urlString: String, withAuth: Bool) async -> (Int, Data?) {
    guard let url = URL(string: urlString) else {
        print("[probe] Bad URL: \(urlString)")
        return (-1, nil)
    }
    var request = URLRequest(url: url)
    if withAuth {
        request.setValue(key, forHTTPHeaderField: "api-subscription-key")
    }
    do {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        return (status, data)
    } catch {
        print("[probe] ERROR: \(error)")
        return (-1, nil)
    }
}

// MARK: - Lifecycle

// 0. Sanity baseline: confirm the sync endpoint still rejects
//    diarization. Establishes the "you must use batch" branch.
print("\n[probe] === Sanity: sync /speech-to-text rejects diarization ===")
do {
    let boundary = "execa-probe-\(UUID().uuidString)"
    var body = Data()
    func append(_ s: String) { body.append(s.data(using: .utf8)!) }
    let prefix = "--\(boundary)\r\n"
    for (name, value) in [("model", model), ("language_code", language), ("with_diarization", "true")] {
        append(prefix)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        append("\(value)\r\n")
    }
    append(prefix)
    append("Content-Disposition: form-data; name=\"file\"; filename=\"hello.wav\"\r\n")
    append("Content-Type: audio/wav\r\n\r\n")
    body.append(wavData)
    append("\r\n--\(boundary)--\r\n")

    var req = URLRequest(url: URL(string: "https://api.sarvam.ai/speech-to-text")!)
    req.httpMethod = "POST"
    req.setValue(key, forHTTPHeaderField: "api-subscription-key")
    req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    req.httpBody = body
    let (data, resp) = try await URLSession.shared.data(for: req)
    let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
    print("[probe] HTTP \(status): \(String(data: data, encoding: .utf8) ?? "<binary>")")
}

// 1. Init job. The /v1 endpoint nests config under `job_parameters`.
//    The legacy /init alias accepts a flat body but silently drops job
//    params; the resulting job stays at total_files=0 forever. /v1 is
//    the canonical endpoint per docs.sarvam.ai.
let (initStatus, initData) = await postJSON(
    endpoint: "https://api.sarvam.ai/speech-to-text/job/v1",
    json: [
        "job_parameters": [
            "model": model,
            "language_code": language,
            "with_diarization": true,
            "input_audio_codec": "wav"
        ]
    ]
)
guard initStatus == 202, let initData,
      let initJSON = try? JSONSerialization.jsonObject(with: initData) as? [String: Any],
      let jobID = initJSON["job_id"] as? String
else {
    print("[probe] Init failed; aborting.")
    exit(1)
}
print("\n[probe] job_id=\(jobID)")
print("[probe] storage_container_type=\(initJSON["storage_container_type"] ?? "<missing>")")

// 2. Get presigned upload URLs. We pass the filenames we intend to
//    upload; Sarvam returns a SAS-style PUT URL per file.
let inputFilename = "hello.wav"
let (uploadURLStatus, uploadURLData) = await postJSON(
    endpoint: "https://api.sarvam.ai/speech-to-text/job/v1/upload-files",
    json: [
        "job_id": jobID,
        "files": [inputFilename]
    ]
)
guard uploadURLStatus == 200, let uploadURLData,
      let uploadJSON = try? JSONSerialization.jsonObject(with: uploadURLData) as? [String: Any],
      let uploadURLs = uploadJSON["upload_urls"] as? [String: Any]
else {
    print("[probe] upload-files request failed; aborting.")
    exit(1)
}

// Each `upload_urls[filename]` is either a string OR an object with
// `file_url`. Sarvam's docs show both shapes — handle both.
func extractURL(_ v: Any) -> String? {
    if let s = v as? String { return s }
    if let dict = v as? [String: Any], let s = dict["file_url"] as? String { return s }
    return nil
}
guard let presignedUploadEntry = uploadURLs[inputFilename],
      let presignedUploadURL = extractURL(presignedUploadEntry)
else {
    print("[probe] No upload URL for \(inputFilename) in response; aborting.")
    exit(1)
}

// 3. PUT the WAV to the presigned URL. Cloud-storage backed (Azure
//    Blob requires the BlockBlob header; presigned-URL Azure happily
//    accepts it on every variant).
let putStatus = await putBlob(
    url: presignedUploadURL,
    data: wavData,
    contentType: "audio/wav",
    isAzureBlob: true
)
guard putStatus == 201 || putStatus == 200 else {
    print("[probe] PUT failed (\(putStatus)); aborting.")
    exit(1)
}

// 4. Start the job.
let (startStatus, _) = await postJSON(
    endpoint: "https://api.sarvam.ai/speech-to-text/job/v1/\(jobID)/start",
    json: [:]
)
guard startStatus == 200 || startStatus == 202 else {
    print("[probe] /start failed (\(startStatus)); aborting.")
    exit(1)
}

// 5. Poll status.
print("\n[probe] === Polling status ===")
var finalStatus: [String: Any]?
for attempt in 1 ... 60 {
    try? await Task.sleep(nanoseconds: 3_000_000_000)
    let (httpStatus, data) = await getURL(
        "https://api.sarvam.ai/speech-to-text/job/v1/\(jobID)/status",
        withAuth: true
    )
    guard let data else {
        print("[probe] poll #\(attempt): no data")
        continue
    }
    let body = String(data: data, encoding: .utf8) ?? "<binary>"
    print("[probe] poll #\(attempt): HTTP \(httpStatus): \(body)")
    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let state = json["job_state"] as? String
    {
        if state.lowercased() == "completed" || state.lowercased() == "succeeded" {
            finalStatus = json
            break
        }
        if state.lowercased() == "failed" {
            print("[probe] Job failed.")
            finalStatus = json
            break
        }
    }
}
guard let finalStatus else {
    print("[probe] Job didn't reach a terminal state in time; aborting.")
    exit(1)
}

// 6. Discover output filenames from the status response, then ask for
//    download URLs.
let jobDetails = (finalStatus["job_details"] as? [[String: Any]]) ?? []
var outputFileNames: [String] = []
for entry in jobDetails {
    if let outputs = entry["outputs"] as? [[String: Any]] {
        for output in outputs {
            if let fileName = output["file_name"] as? String {
                outputFileNames.append(fileName)
            }
        }
    }
}
if outputFileNames.isEmpty {
    // Fallback: the docs sometimes auto-name as `<input>.json`.
    outputFileNames = ["hello.json", "hello.wav.json"]
    print("[probe] No outputs in job_details; falling back to candidates: \(outputFileNames)")
} else {
    print("[probe] Output files from status: \(outputFileNames)")
}

let (downloadStatus, downloadData) = await postJSON(
    endpoint: "https://api.sarvam.ai/speech-to-text/job/v1/download-files",
    json: [
        "job_id": jobID,
        "files": outputFileNames
    ]
)
guard downloadStatus == 200, let downloadData,
      let downloadJSON = try? JSONSerialization.jsonObject(with: downloadData) as? [String: Any],
      let downloadURLs = downloadJSON["download_urls"] as? [String: Any]
else {
    print("[probe] download-files failed; aborting.")
    exit(1)
}

// 7. GET each presigned download URL, capture the first successful
//    JSON to the fixture file.
var capturedTo: URL?
for fileName in outputFileNames {
    guard let entry = downloadURLs[fileName],
          let url = extractURL(entry)
    else {
        print("[probe] No download URL for \(fileName); skipping.")
        continue
    }
    let (status, data) = await getURL(url, withAuth: false)
    print("\n[probe] === GET \(fileName): HTTP \(status) ===")
    guard let data else { continue }
    let bodyString = String(data: data, encoding: .utf8) ?? "<binary>"
    print("[probe] Body: \(bodyString)")
    if status == 200, capturedTo == nil {
        // Pretty-print before writing so the fixture diffs cleanly.
        if let parsed = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: parsed, options: [.prettyPrinted, .sortedKeys])
        {
            try? pretty.write(to: resultFixtureURL)
        } else {
            try? data.write(to: resultFixtureURL)
        }
        capturedTo = resultFixtureURL
    }
}
if let capturedTo {
    print("\n[probe] Wrote result fixture to \(capturedTo.path)")
} else {
    print("\n[probe] WARNING: no result fixture captured.")
}
