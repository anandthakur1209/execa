import Foundation

/// Parsed Sarvam batch STT response with `with_diarization=true`.
///
/// Wire shape captured by `scripts/sarvam-batch-probe.swift` and the
/// fixture at `Execa/ExecaTests/Fixtures/sarvam-batch-result-sample.json`.
/// Parser converts wire types to schema-friendly types at this boundary:
///
///  - Wire `speaker_id` is a String (`"0"`); we convert to Int and fail
///    fast if it's non-numeric. The `speakers.raw_speaker_id` column is
///    an INTEGER, and a non-numeric ID would mean Sarvam changed the
///    contract — better to error than silently misattribute.
///  - Wire `start_time_seconds` / `end_time_seconds` are Doubles in
///    seconds. We multiply by 1000 and round to match
///    `transcript_segments.start_ms` / `end_ms` (INTEGER ms).
///  - `language_code` is top-level on the wire. We copy it into each
///    `BatchSegment.languageCode` so callers don't have to pass the
///    top-level alongside each segment.
///
/// `DiarizationService.swapInDatabase` rebases these `speakerID`s into
/// the per-meeting `(source, raw_speaker_id)` space — within one batch
/// result `speakerID` is meaningful only relative to the file submitted.
struct SarvamBatchResult: Equatable {
    var segments: [BatchSegment]

    /// One diarized segment as the batch endpoint emits it. `speakerID`
    /// is the cluster ID Sarvam assigns within this single batch call —
    /// it is meaningful only relative to the file submitted, not across
    /// files (we submit `mic.wav` and `system.wav` separately, so a
    /// `speakerID` of `0` in the mic result and `0` in the system
    /// result are unrelated speakers).
    struct BatchSegment: Equatable {
        var speakerID: Int
        var startMs: Int
        var endMs: Int
        var text: String
        var languageCode: String?
    }
}

// MARK: - Parser

extension SarvamBatchResult {
    /// Decodes a raw Sarvam batch result-JSON (the per-file `*.json`
    /// blob the download-files endpoint hands us — see the
    /// 2026-05-09 DECISIONS entry for the full wire shape).
    static func decode(_ data: Data) throws -> SarvamBatchResult {
        let decoder = JSONDecoder()
        let wire: SarvamBatchWirePayload
        do {
            wire = try decoder.decode(SarvamBatchWirePayload.self, from: data)
        } catch {
            throw SarvamBatchClientError.decodingFailed(
                "top-level JSON: \(error.localizedDescription)"
            )
        }

        let topLanguage = wire.languageCode
        let entries = wire.diarizedTranscript?.entries ?? []
        var segments: [BatchSegment] = []
        segments.reserveCapacity(entries.count)
        for (index, entry) in entries.enumerated() {
            // Sarvam's wire `speaker_id` is a string ("0", "1"). We
            // require a numeric string here because `raw_speaker_id` is
            // an INTEGER column — and silently accepting a string value
            // would let a contract change pass unnoticed.
            guard let parsedSpeakerID = Int(entry.speakerID) else {
                throw SarvamBatchClientError.decodingFailed(
                    "entry[\(index)] non-numeric speaker_id=\"\(entry.speakerID)\""
                )
            }
            let startMs = Int((entry.startTimeSeconds * 1000).rounded())
            let endMs = Int((entry.endTimeSeconds * 1000).rounded())
            segments.append(
                BatchSegment(
                    speakerID: parsedSpeakerID,
                    startMs: startMs,
                    endMs: endMs,
                    text: entry.transcript,
                    languageCode: topLanguage
                )
            )
        }
        return SarvamBatchResult(segments: segments)
    }
}

// MARK: - Wire types (file-private)

//
// Lifted to top level rather than nested inside `SarvamBatchResult` so
// each type's `CodingKeys` enum stays at nesting depth 1 (the linter
// rejects depth ≥ 2). Behaviour is unchanged.

private struct SarvamBatchWirePayload: Decodable {
    let languageCode: String?
    let diarizedTranscript: SarvamBatchDiarizedTranscript?

    enum CodingKeys: String, CodingKey {
        case languageCode = "language_code"
        case diarizedTranscript = "diarized_transcript"
    }
}

private struct SarvamBatchDiarizedTranscript: Decodable {
    let entries: [SarvamBatchEntry]
}

private struct SarvamBatchEntry: Decodable {
    let transcript: String
    let startTimeSeconds: Double
    let endTimeSeconds: Double
    let speakerID: String

    enum CodingKeys: String, CodingKey {
        case transcript
        case startTimeSeconds = "start_time_seconds"
        case endTimeSeconds = "end_time_seconds"
        case speakerID = "speaker_id"
    }
}
