@testable import Execa
import Foundation
import Testing

/// Parser tests against the captured wire fixture
/// `Execa/ExecaTests/Fixtures/sarvam-batch-result-sample.json`. Locks
/// the boundary conversions:
///   - String `speaker_id` → Int `speakerID`
///   - Double seconds → Int milliseconds (rounded)
///   - Top-level `language_code` → per-segment `languageCode`
struct SarvamBatchClientParserTests {
    @Test func parsesCapturedSampleFixture() throws {
        let bundle = Bundle(for: BundleAnchor.self)
        let url = try #require(
            bundle.url(forResource: "sarvam-batch-result-sample", withExtension: "json")
        )
        let data = try Data(contentsOf: url)
        let result = try SarvamBatchResult.decode(data)

        try #require(result.segments.count == 1, "fixture has one diarized entry")
        let segment = result.segments[0]
        #expect(segment.speakerID == 0, "wire \"0\" → Int 0")
        #expect(segment.text == "Hello. This is a phase two transcription test.")
        // 0.01 s → 10 ms, 3.29 s → 3290 ms.
        #expect(segment.startMs == 10)
        #expect(segment.endMs == 3290)
        #expect(segment.languageCode == "en-IN", "top-level language_code copies into each segment")
    }

    @Test func parsesMultipleEntriesPreservingOrder() throws {
        let json = """
        {
          "request_id": "test",
          "transcript": "ignored",
          "language_code": "hi-IN",
          "diarized_transcript": {
            "entries": [
              {"transcript": "first", "start_time_seconds": 0.0,  "end_time_seconds": 1.5,  "speaker_id": "0"},
              {"transcript": "second","start_time_seconds": 1.5,  "end_time_seconds": 3.25, "speaker_id": "1"},
              {"transcript": "third", "start_time_seconds": 3.25, "end_time_seconds": 4.876,"speaker_id": "0"}
            ]
          }
        }
        """
        let result = try SarvamBatchResult.decode(Data(json.utf8))
        #expect(result.segments.count == 3)
        #expect(result.segments[0].speakerID == 0)
        #expect(result.segments[1].speakerID == 1)
        #expect(result.segments[2].speakerID == 0)
        #expect(result.segments[0].text == "first")
        #expect(result.segments[1].text == "second")
        #expect(result.segments[2].text == "third")
        // Rounding check: 4.876 s × 1000 = 4876 ms.
        #expect(result.segments[2].endMs == 4876)
        // 3.25 s × 1000 = 3250 ms (no rounding ambiguity).
        #expect(result.segments[1].endMs == 3250)
        for segment in result.segments {
            #expect(segment.languageCode == "hi-IN")
        }
    }

    @Test func handlesEmptyEntriesArray() throws {
        let json = """
        {
          "request_id": "test",
          "transcript": "",
          "language_code": "en-IN",
          "diarized_transcript": {"entries": []}
        }
        """
        let result = try SarvamBatchResult.decode(Data(json.utf8))
        #expect(result.segments.isEmpty)
    }

    @Test func handlesMissingDiarizedTranscript() throws {
        // If Sarvam ever sends a result without a diarized_transcript
        // block (e.g. an empty WAV that returned only the top-level
        // transcript), we treat it as zero-segments rather than
        // throwing — DiarizationService can decide what to do.
        let json = """
        {"request_id": "x", "transcript": "", "language_code": "en-IN"}
        """
        let result = try SarvamBatchResult.decode(Data(json.utf8))
        #expect(result.segments.isEmpty)
    }

    @Test func nonNumericSpeakerIDFailsLoudly() {
        // Non-numeric speaker_id is a contract change — fail rather
        // than silently dropping or remapping the segment.
        let json = """
        {
          "request_id": "x",
          "language_code": "en-IN",
          "diarized_transcript": {
            "entries": [
              {"transcript": "x", "start_time_seconds": 0.0, "end_time_seconds": 1.0, "speaker_id": "alice"}
            ]
          }
        }
        """
        #expect(throws: SarvamBatchClientError.self) {
            _ = try SarvamBatchResult.decode(Data(json.utf8))
        }
    }

    @Test func malformedTopLevelJSONFailsLoudly() {
        let bad = Data("not json at all".utf8)
        #expect(throws: SarvamBatchClientError.self) {
            _ = try SarvamBatchResult.decode(bad)
        }
    }
}

/// Bundle anchor: `Bundle(for: BundleAnchor.self)` resolves the test
/// target's resource bundle, where `Fixtures/*.json` live (Xcode's file
/// synchronized group flattens fixture filenames into the bundle).
private final class BundleAnchor {}
