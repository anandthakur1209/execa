import Foundation

/// Sarvam batch Speech-to-Text client. Submits a finalized WAV file to
/// the v1 batch endpoint with `with_diarization=true`, walks the
/// six-step lifecycle (init → presign → upload → start → poll → fetch),
/// and returns the parsed `SarvamBatchResult`.
///
/// Wire format — endpoint paths, request/response shapes — locked in
/// the 2026-05-09 DECISIONS.md entry; the captured probe lives at
/// `scripts/sarvam-batch-probe.swift` and the result fixture is at
/// `Execa/ExecaTests/Fixtures/sarvam-batch-result-sample.json`.
///
/// Why no `SarvamBatchClientProtocol`: tests inject a separate mock
/// type (`MockSarvamBatchClient`) via the closure factory in
/// `DiarizationService.init`. If a third batch provider ever lands
/// (Phase 6+), extract a protocol then.
actor SarvamBatchClient {
    private let apiKey: String
    private let baseURL: URL
    private let session: URLSession
    /// Wall-clock budget for the whole job. Shorter files (a few
    /// minutes) usually return in seconds; long meetings (~30 min)
    /// can take 30–60 s end-to-end. We give the job 5 minutes before
    /// surfacing a timeout error — an upper bound that covers the
    /// hour-long files Sarvam advertises support for, with margin.
    private let pollTimeout: Duration
    /// Time between status polls. Sarvam's docs ask for ≥5 ms; we use
    /// 3 s to keep the API hit-rate gentle on long-running jobs.
    private let pollInterval: Duration

    /// Production initializer. The hardcoded base URL is a compile-time
    /// constant; the force-unwrap is safe and the lint exception is a
    /// per-line disable (same pattern other production hardcoded URLs
    /// would use — none currently exist in the codebase, but the
    /// alternative of building via `URLComponents` and a fallback adds
    /// noise for no behavioural difference).
    init(apiKey: String) {
        self.apiKey = apiKey
        // swiftlint:disable:next force_unwrapping
        baseURL = URL(string: "https://api.sarvam.ai")!
        session = URLSession.shared
        pollTimeout = .seconds(300)
        pollInterval = .seconds(3)
    }

    /// Test/override initializer. `baseURL` lets tests aim a fake server
    /// at a localhost port; the polling knobs let test scenarios resolve
    /// quickly instead of burning real wall-clock time.
    init(
        apiKey: String,
        baseURL: URL,
        session: URLSession = .shared,
        pollTimeout: Duration = .seconds(300),
        pollInterval: Duration = .seconds(3)
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.session = session
        self.pollTimeout = pollTimeout
        self.pollInterval = pollInterval
    }

    /// Submits `wavURL` to the Sarvam batch endpoint and returns the
    /// parsed diarized result. `languageCode` is e.g. `"en-IN"` —
    /// Sarvam uses this for STT and tags it on the response.
    func diarize(wavURL: URL, languageCode: String) async throws -> SarvamBatchResult {
        let wavData: Data
        do {
            wavData = try Data(contentsOf: wavURL)
        } catch {
            throw SarvamBatchClientError.invalidURL
        }
        // Use a stable filename across the lifecycle. The same name
        // appears in the upload-files request, the PUT URL Sarvam
        // returns, and (via index) the result-file naming.
        let inputFilename = wavURL.lastPathComponent

        // 1. Init job.
        let jobID = try await initJob(languageCode: languageCode)

        // 2. Get presigned upload URL for our input file.
        let uploadURL = try await requestUploadURL(jobID: jobID, filename: inputFilename)

        // 3. PUT the WAV directly to Azure Blob via the presigned URL.
        try await uploadWAV(presignedURL: uploadURL, wavData: wavData)

        // 4. Start the job.
        try await startJob(jobID: jobID)

        // 5. Poll status until terminal. Returns the names of the
        //    output JSON files Sarvam produced.
        let outputFilenames = try await waitForCompletion(jobID: jobID)

        // 6. Get presigned download URL for the first output file
        //    (we submit one file per job, so there's one output).
        guard let outputFilename = outputFilenames.first else {
            throw SarvamBatchClientError.uploadFailed(
                statusCode: 0,
                message: "job completed without producing any output files"
            )
        }
        let downloadURL = try await requestDownloadURL(
            jobID: jobID,
            filename: outputFilename
        )

        // 7. Fetch the result JSON and parse.
        let resultData = try await fetchResult(presignedURL: downloadURL)
        return try SarvamBatchResult.decode(resultData)
    }

    // MARK: - Lifecycle steps

    private func initJob(languageCode: String) async throws -> String {
        let body: [String: Any] = [
            "job_parameters": [
                "model": "saarika:v2.5",
                "language_code": languageCode,
                "with_diarization": true,
                "input_audio_codec": "wav"
            ]
        ]
        let url = baseURL.appendingPathComponent("speech-to-text/job/v1")
        let (data, status) = try await postJSON(url: url, body: body)
        guard status == 202 else {
            throw SarvamBatchClientError.uploadFailed(
                statusCode: status,
                message: "job init: \(stringify(data))"
            )
        }
        let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard let jobID = parsed?["job_id"] as? String, !jobID.isEmpty else {
            throw SarvamBatchClientError.decodingFailed(
                "job init response missing job_id"
            )
        }
        return jobID
    }

    private func requestUploadURL(jobID: String, filename: String) async throws -> URL {
        let url = baseURL.appendingPathComponent("speech-to-text/job/v1/upload-files")
        let body: [String: Any] = ["job_id": jobID, "files": [filename]]
        let (data, status) = try await postJSON(url: url, body: body)
        guard status == 200 else {
            throw SarvamBatchClientError.uploadFailed(
                statusCode: status,
                message: "upload-files: \(stringify(data))"
            )
        }
        let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let uploads = parsed?["upload_urls"] as? [String: Any]
        guard let entry = uploads?[filename],
              let urlString = extractFileURL(entry),
              let presigned = URL(string: urlString)
        else {
            throw SarvamBatchClientError.decodingFailed(
                "upload-files response missing upload_urls[\(filename)].file_url"
            )
        }
        return presigned
    }

    private func uploadWAV(presignedURL: URL, wavData: Data) async throws {
        var request = URLRequest(url: presignedURL)
        request.httpMethod = "PUT"
        request.setValue("BlockBlob", forHTTPHeaderField: "x-ms-blob-type")
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.upload(for: request, from: wavData)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 201 || status == 200 else {
            throw SarvamBatchClientError.uploadFailed(
                statusCode: status,
                message: "PUT to presigned URL: \(stringify(data))"
            )
        }
    }

    private func startJob(jobID: String) async throws {
        let url = baseURL
            .appendingPathComponent("speech-to-text/job/v1")
            .appendingPathComponent(jobID)
            .appendingPathComponent("start")
        let (data, status) = try await postJSON(url: url, body: [:])
        guard status == 200 || status == 202 else {
            throw SarvamBatchClientError.uploadFailed(
                statusCode: status,
                message: "start job: \(stringify(data))"
            )
        }
    }

    private func waitForCompletion(jobID: String) async throws -> [String] {
        let url = baseURL
            .appendingPathComponent("speech-to-text/job/v1")
            .appendingPathComponent(jobID)
            .appendingPathComponent("status")
        let deadline = ContinuousClock.now.advanced(by: pollTimeout)
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: pollInterval)
            var request = URLRequest(url: url)
            request.setValue(apiKey, forHTTPHeaderField: "api-subscription-key")
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard status == 200 else {
                throw SarvamBatchClientError.uploadFailed(
                    statusCode: status,
                    message: "status poll: \(stringify(data))"
                )
            }
            let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let state = (parsed?["job_state"] as? String) ?? ""
            switch state.lowercased() {
            case "completed", "succeeded":
                return extractOutputFilenames(parsed)
            case "failed":
                let message = (parsed?["error_message"] as? String) ?? state
                throw SarvamBatchClientError.uploadFailed(
                    statusCode: 0,
                    message: "job failed: \(message)"
                )
            default:
                continue
            }
        }
        throw SarvamBatchClientError.uploadFailed(
            statusCode: 0,
            message: "job did not reach a terminal state within the poll budget"
        )
    }

    private func extractOutputFilenames(_ parsed: [String: Any]?) -> [String] {
        guard let details = parsed?["job_details"] as? [[String: Any]] else { return [] }
        var result: [String] = []
        for entry in details {
            guard let outputs = entry["outputs"] as? [[String: Any]] else { continue }
            for output in outputs {
                if let name = output["file_name"] as? String, !name.isEmpty {
                    result.append(name)
                }
            }
        }
        return result
    }

    private func requestDownloadURL(jobID: String, filename: String) async throws -> URL {
        let url = baseURL.appendingPathComponent("speech-to-text/job/v1/download-files")
        let body: [String: Any] = ["job_id": jobID, "files": [filename]]
        let (data, status) = try await postJSON(url: url, body: body)
        guard status == 200 else {
            throw SarvamBatchClientError.uploadFailed(
                statusCode: status,
                message: "download-files: \(stringify(data))"
            )
        }
        let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let downloads = parsed?["download_urls"] as? [String: Any]
        guard let entry = downloads?[filename],
              let urlString = extractFileURL(entry),
              let presigned = URL(string: urlString)
        else {
            throw SarvamBatchClientError.decodingFailed(
                "download-files response missing download_urls[\(filename)].file_url"
            )
        }
        return presigned
    }

    private func fetchResult(presignedURL: URL) async throws -> Data {
        // Presigned URL carries its own SAS signature; do not attach
        // the api-subscription-key header here.
        let (data, response) = try await session.data(from: presignedURL)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            throw SarvamBatchClientError.uploadFailed(
                statusCode: status,
                message: "GET result: \(stringify(data))"
            )
        }
        return data
    }

    // MARK: - Helpers

    private func postJSON(url: URL, body: [String: Any]) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "api-subscription-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        return (data, status)
    }

    /// Sarvam's `upload_urls` / `download_urls` map values are objects
    /// with `file_url` keys (Azure_V1 container). Older docs imply
    /// they could be plain strings; handle both shapes defensively.
    private func extractFileURL(_ value: Any) -> String? {
        if let direct = value as? String { return direct }
        if let dict = value as? [String: Any], let nested = dict["file_url"] as? String { return nested }
        return nil
    }

    private func stringify(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? "<binary \(data.count) bytes>"
    }
}

enum SarvamBatchClientError: Error, Equatable {
    /// Reading the WAV file from disk failed (path missing, permissions).
    case invalidURL
    /// Any non-success HTTP status from Sarvam or a presigned URL.
    /// `statusCode == 0` indicates a non-HTTP failure (job failed, poll
    /// budget exhausted, missing output file).
    case uploadFailed(statusCode: Int, message: String)
    /// JSON didn't match the expected wire shape — typically a
    /// non-numeric `speaker_id` or a missing required field.
    case decodingFailed(String)
}
