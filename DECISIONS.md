# DECISIONS.md

Append-only log of architectural decisions for **execa**. Each entry: date, decision, rationale, status. Do not edit prior entries — supersede with a new entry if a decision is reversed.

The full reasoning lives in `meeting-app-spec.md`; this file is the index so Claude Code does not re-litigate settled questions.

---

## 2026-05-05 — App stack: native Swift / SwiftUI

- **Decision:** macOS 14+ native Swift app. SwiftUI-first; AppKit only where SwiftUI is insufficient (status item, system permission prompts).
- **Alternatives considered:** Electron + TypeScript, Python + Tauri/PyQt menu bar.
- **Why:** Lowest-latency audio path, ScreenCaptureKit access without virtual-driver hacks, single-binary install, easiest signing/notarization story.
- **Status:** Active.

## 2026-05-05 — STT primary: Sarvam Saaras V3

- **Decision:** Sarvam Saaras V3 streaming WebSocket is the default STT, with `language=hi-en` for Hinglish meetings. Deepgram Nova-3 multilingual is the auto-failover. Soniox and AssemblyAI are alternative adapters, not defaults.
- **Why:** User's meetings frequently mix Hindi and English mid-sentence. Sarvam was trained on 1M+ hours of code-mixed Indian audio and ships a streaming-first architecture with sub-150 ms time-to-first-token and code-switch-stable diarization. Deepgram is a more mature vendor and a better pure-English choice — kept as failover and as a Settings option.
- **Reconsider after:** ~30 days of real meetings; if Sarvam diarization or uptime under-performs, flip the default to Deepgram in Settings without code change.
- **Status:** Active.

## 2026-05-05 — Speaker identification: anonymous + manual rename for v1

- **Decision:** v1 ships anonymous diarization with mid-meeting renaming, merging, and splitting. No cross-meeting voice enrollment.
- **Why:** Lowest-friction path to a working product; the schema (`speakers.embedding BLOB NULLABLE`) is already shaped to add enrollment in v2 without migration.
- **v2 sketch:** ECAPA-TDNN embeddings via pyannote 3.1 (CoreML/ONNX), `known_speakers` table, threshold-based auto-tagging.
- **Status:** Active. v2 enrollment parked.

## 2026-05-05 — Storage: local-only, cloud only for inference

- **Decision:** Audio, transcripts, summaries, and MOMs live exclusively on the local machine in the sandbox container. Outbound traffic only to the active STT provider and the configured LLM provider.
- **Why:** Privacy posture appropriate for executive meetings.
- **Status:** Active.

## 2026-05-05 — LLM routing: in-process Swift `LLMRouter`, LiteLLM-compatible config

- **Decision:** Use a Swift-native `LLMRouter` that reads a LiteLLM-compatible YAML config. Do **not** bundle the LiteLLM Python proxy in the installer.
- **Alternatives considered:** Bundle LiteLLM as a PyInstaller-built child binary; require the user to run LiteLLM in Docker.
- **Why:** Keeps distribution to a single Universal2 Swift binary (~25 MB instead of ~250 MB), no Python notarization complexity, no `master_key` exposure on a localhost proxy, no startup latency from a child process. The user requirement was "a router *like* LiteLLM" — the YAML schema preserves LiteLLM compatibility, and Settings → Advanced → Router URL lets power users point at a real LiteLLM proxy later via the `LLMTransport` abstraction.
- **Status:** Active.

## 2026-05-05 — Default LLM: Claude Sonnet 4.6

- **Decision:** Default both `summary-deep` and `mom-default` aliases to Claude Sonnet 4.6 (Anthropic). `summary-fast` defaults to Claude Haiku 4.5. GPT-4.1 and Gemini 2.5 Pro configured as fallbacks.
- **Why:** Sonnet 4.6 handles Devanagari and code-mixed text well; reasoning quality on long transcripts is strong; user already uses Anthropic.
- **Status:** Active.

## 2026-05-05 — Distribution: Developer ID + DMG + Sparkle, not Mac App Store

- **Decision:** Direct distribution via notarized DMG with Sparkle auto-update. Mac App Store is ruled out.
- **Why:** ScreenCaptureKit + system-audio capture is impractical under MAS sandbox restrictions; peer products (Granola, Loom, Rewind) all distribute outside MAS for the same reason.
- **Status:** Active.

## 2026-05-05 — Telemetry: none. Crash reporting: opt-in, off by default.

- **Decision:** No usage analytics. Crash reporting via MetricKit + Sentry is a Settings toggle, default off, with a scrubber that strips Keychain key prefixes and `~/Library/Application Support/...` paths before submission.
- **Why:** Executive-meeting tool — privacy stance is a feature.
- **Status:** Active.

## 2026-05-06 — Product naming and bundle identifier

- **Decision:** Product name **execa** (lowercase) for user-facing surfaces; **Execa** (PascalCase) for Xcode project, Swift module, and bundle target; bundle ID `com.anandthakur.execa`. Apple Developer Team is the user's personal enrollment.
- **Why:** Matches user preference; avoids Reliance Org dependency that hasn't been arranged. A Reliance Team ID can be added later as a parallel build configuration if internal distribution is needed.
- **Status:** Active.

## 2026-05-06 — Sandbox file paths rooted at bundle ID

- **Decision:** All persistent files live under `~/Library/Application Support/com.anandthakur.execa/` and `~/Library/Caches/com.anandthakur.execa/`. Anything else triggers Full-Disk-Access prompts and breaks the sandbox story.
- **Why:** Sandbox compliance; `FileManager.default.url(for: .applicationSupportDirectory, …)` resolves to this path automatically when the app is signed with the matching bundle ID.
- **Status:** Active.

## 2026-05-06 — Voice enrollment and Otter-style sample tagging: parked

- **Decision:** Cross-meeting voice enrollment and the Otter-style "tag a sample, find similar" affordance are explicitly out of scope for v1. Schema reserves `speakers.embedding` for forward compatibility.
- **Why:** Keep v1 simple; revisit after real-meeting usage data shows whether per-meeting renaming friction justifies the work.
- **Status:** Parked.

## 2026-05-06 — Project structure: native `.xcodeproj`, no XcodeGen / Tuist

- **Decision:** The `Execa.xcodeproj` is created from the standard Xcode macOS App template (Xcode 26.4.1) and edited directly. No XcodeGen, no Tuist.
- **Alternatives considered:** XcodeGen with checked-in `project.yml`, Tuist, hand-rolled `project.pbxproj`.
- **Why:** Single-target app (one app + one test target). The cost of carrying a project-generation tool exceeds the benefit at this size, and Apple's template gets sandbox/entitlements/signing defaults right that we'd otherwise rediscover by losing an afternoon.
- **Status:** Active.

## 2026-05-06 — Test framework: Swift Testing

- **Decision:** Unit and integration tests use Swift Testing (`@Test`, `#expect`). XCTest is only acceptable inside a UI-test target if one is ever added (UI tests still require XCUI / XCTest).
- **Alternatives considered:** XCTest for everything; mixed (XCTest unit + Swift Testing integration).
- **Why:** Xcode 26.4.1 ships a mature Swift Testing toolchain. The framework's async-first design matches execa's actor-based architecture, eliminates the expectation/fulfillment boilerplate XCTest requires for async work, and gives us parametrized tests via `@Test(arguments: ...)` for provider-matrix coverage (Sarvam vs Deepgram, prompt-template variants). No legacy XCTest code to migrate.
- **Status:** Active. Supersedes the earlier "XCTest for v1" note in `CLAUDE.md`.

### 2026-05-06 — Project structure: native `.xcodeproj`, no XcodeGen / Tuist

- **Decision:** The `Execa.xcodeproj` is created from the standard Xcode macOS App template and edited directly. No XcodeGen, no Tuist.
- **Why:** Single-target app; the cost of adding a project-generation tool exceeds the benefit at this size.
- **Status:** Active.

## 2026-05-06 — Phase 1: master.flac is mono and post-processed at stop()

- **Decision:** The downmixed `master.flac` is generated by `AudioMixer.writeMasterFLAC` at the end of `AudioCaptureService.stop()` from the finalised `mic.wav` + `system.wav`, not live-mixed during capture. Output is mono 48 kHz Int16 FLAC, summed `(mic + system) / 2`.
- **Alternatives considered:** Live mixing during capture (writes one file with no separate per-source archive); stereo `mic-L / system-R` master.
- **Why:** Live mixing requires a synchronized clock between SCK's `CMTime` and `AVAudioEngine`'s `AVAudioTime`; doable, but a substantial Phase 1 timesink for marginal value. Mono matches the STT-format pipeline and what peer apps (Granola / Loom) emit. Stereo "mic-L / system-R" is useful for forensics but loses fidelity for system audio that's already stereo. Spec §4.1 calls for "a mixed master" without specifying timing or layout; BUILD_PLAN Phase 1 says "downmixed master.flac" with the same latitude.
- **Status:** Active. Per-source first-frame timestamp alignment in the mix-down is a Phase 5 follow-up (`// FIXME(phase-5)` in `AudioMixer.swift`, tracked in `BUILD_PLAN.md`).

## 2026-05-06 — Phase 1: meeting IDs are ULID via inline implementation

- **Decision:** Meeting IDs are ULIDs generated by an inline ~30-line `Util/ULID.swift` (Crockford base32 of [48-bit ms timestamp + 80-bit random]). No new SPM dependency.
- **Alternatives considered:** UUID strings; an external ULID Swift package.
- **Why:** Spec §7's `meetings.id TEXT PRIMARY KEY` is opaque to any specific encoding, so UUID would have worked, but ULIDs sort lexicographically by generation time — which Phase 5's History view relies on for chronological listing without a separate ORDER BY started_at clause. Pulling a third-party package for 30 lines of well-defined code crosses the bar the SPM-only rule is trying to keep low.
- **Status:** Active.

## 2026-05-06 — Phase 1: archival format locked to 48 kHz Int16 mono per source

- **Decision:** Both `mic.wav` and `system.wav` are 48 kHz Int16 mono. `master.flac` is 48 kHz Int16 mono. The STT-format pipeline emits 16 kHz Int16 mono `PCMChunk`s in parallel for Phase 2's Sarvam / Deepgram adapters.
- **Alternatives considered:** Preserving native source rates and channel counts in the .wav archives (e.g. SCK's 48 kHz Float32 stereo); 16 kHz mono everywhere; a higher-resolution 96 kHz archive.
- **Why:** 48 kHz Int16 mono is the lowest-overhead format that doesn't lose meaningful fidelity for human speech (the dominant signal in a meeting recording), keeps file sizes ~1.5 MB/min FLAC per spec §10, and decouples the archive from any individual source's native quirks. Phase 5 history-view playback and Phase 4 LLM re-summarisation both depend on this contract being stable.
- **Status:** Active.

## 2026-05-07 — Phase 1 bug-fix: `AVAudioConverter` streaming uses `.noDataNow`, never `.endOfStream`

- **Decision:** Every place we drive `AVAudioConverter.convert(to:error:withInputFrom:)` in a streaming pipeline (mic archival, SCK archival, `AudioResampler` STT) signals `.noDataNow` after handing over a single input buffer — never `.endOfStream`. The converter is reused across many calls; signalling `.endOfStream` permanently closes the converter's input stream and turns every subsequent `convert(to:)` into a 0-frame no-op.
- **Why this matters:** Phase 1 manual smoke surfaced `mic.wav` of ~14 KB and `system.wav` of ~4 KB after multi-second recordings. The structurally-correct files contained only the very first buffer's worth of frames. Diagnostic counters proved the source callbacks kept firing — every subsequent buffer went through `convert()`, but `output.frameLength` was 0. The bug was in the converter's input-block contract: `.endOfStream` is for stream termination, `.noDataNow` is for "I'll provide more later." The streaming-friendly signal preserves converter state between calls.
- **Trade-off:** With `.noDataNow`, the converter holds ~50–100 ms of trailing frames internally to feed its filter taps on the next call. In a meeting those frames flow out via the next buffer; only the last <100 ms of the final input buffer at meeting end is unrecoverable. Tests assert tolerance (±1600 frames @ 16 kHz = ~100 ms) on a single-buffer conversion that mirrors this trailing-frame behaviour.
- **Other Phase 1 bugs landed in the same fix commit** (recorded here so we don't re-litigate):
  - **`SCKTapHandler.makePCMBuffer`**: replaced the manually-walked, single-buffer `AudioBufferList` with `CMSampleBufferCopyPCMDataIntoAudioBufferList` writing into `pcmBuffer.mutableAudioBufferList`. The old form was undersized for SCStream's stereo non-interleaved system audio and silently dropped every buffer (and hence every write) at extraction time.
  - **`Execa.entitlements`**: added the `com.apple.security.exception.mach-lookup.global-name` exception for `com.apple.audioanalyticsd`. AVAudioEngine on a sandboxed macOS 14 app prints `[carc] PRECONDITION FAILURE: Process is sandboxed but ... doesn't contain 'com.apple.audioanalyticsd'` on every start. The exception is narrow (one named service), is the standard fix in Apple developer forum threads, and does not weaken `library-validation` or `app-sandbox`. CLAUDE.md's "no `allow-jit`, no `disable-library-validation`" rule is preserved.
- **Regression-test coverage:** `MicrophoneSourceTests.capturesAudioToWAV` and `ScreenCaptureKitSourceTests.capturesSystemAudioToWAV` now assert frame-count floors (60% and 50% of expected) instead of `> 0`. New `AudioCaptureServiceTests.continuousBufferEmissionLandsAllFrames` drives a `WritingStubAudioSource` that emits 100 PCM buffers over 1 s and asserts the file contains ≥ 90% of them — catches writer-side and orchestrator-side regressions without needing real CoreAudio permissions.
- **Status:** Active.

## 2026-05-07 — Phase 1 closeout: acoustic echo cancellation deferred

- **Decision:** Phase 1 audio capture assumes headphones use; speaker mode produces echo bleed in `mic.wav`. Voice Processing IO via `kAUVoiceProcessingIO` is the standard fix (used by Zoom/Meet) but adds latency, may conflict with concurrent SCK capture, and isn't needed for the headphones use case. Revisit if user testing surfaces speaker-mode as a real workflow.
- **Why:** Phase 1 manual smoke confirmed correct two-stream capture when the user is on headphones — `mic.wav` has only the user's voice, `system.wav` has only remote/system audio, `master.flac` mixes the two cleanly. With built-in speakers, remote audio plays into the room and the mic re-captures it; the same speech then appears in both archives and would yield doubled transcript entries in Phase 2 (mic-stream tagged as "You", system-stream correctly diarized). This is acoustic physics, not a Phase 1 capture bug. AEC adds complexity (Voice Processing IO renegotiates the input audio format, may interact poorly with `AVAudioEngineConfigurationChange`, and adds 20–40 ms of latency) for a use case the product does not target.
- **Mitigation if it becomes blocking:** Switch the mic input from a raw `AVAudioEngine` tap to `kAUVoiceProcessingIO` (an audio unit), or wait for the macOS 15+ `SCStream.captureMicrophone` path which routes mic through SCK and avoids the dual-engine collision entirely.
- **Status:** Parked.

## 2026-05-08 — Phase 2: mic stream is now diarized too (supersedes spec §4.2 `diarization=false` for mic)

- **Decision:** Both `SarvamProvider` instances — mic and system — connect with `diarization=true`. Default labels assigned at first-seen `(source, raw_speaker_id)`: `(mic, 0)` → `settings.displayName` (fallback `"You"`); `(mic, N≥1)` → `"In-room \(N+1)"`; `(system, N)` → `"Speaker \(N+1)"`. The `(meeting_id, source, raw_speaker_id)` UNIQUE key in the existing `speakers` schema already supports the multi-speaker mic case — no migration needed.
- **Supersedes:** spec §4.2 prior wording "Mic stream: `diarization=false` (mic = local user, always)." Spec §4.1 / §4.2 / §6.1 rewritten accordingly. CLAUDE.md's "Mic and system audio streams stay separate end-to-end" non-negotiable kept; rationale rewritten to cite per-stream diarization quality and the data-model source distinction (no longer "the 'You' label depends on it").
- **Why:** Multi-person in-room meetings around one MacBook are a real workflow — particularly hybrid setups where some participants are in the room and others dial in via Zoom. The original "mic = always one person" assumption produced a single transcript line collapsing all in-room voices, lossy in exactly the scenario the product needs to handle. With both streams diarized, the in-room participants get `In-room 2/3/...` labels and the remote participants get `Speaker 1/2/...`; the user's own voice is `displayName` regardless of source. The cost (one extra `diarization=true` query param on the mic socket) is trivial.
- **Status:** Active. Phase 3 adds a rename UI on top of these defaults.

## 2026-05-08 — Phase 2: 30 s reconnect ring buffer is sized by frame count, not chunk count

- **Decision:** `AudioRingBuffer` retains the most recent N audio frames per source (default 480 000 = 30 s at 16 kHz). Push appends; if `totalFrames > maxFrames`, oldest chunks are dropped until back under cap. `drain()` returns all retained chunks in insertion order and clears the buffer.
- **Alternatives considered:** Sizing by chunk count (e.g. "last 100 chunks"). Sizing by wall-clock seconds.
- **Why:** Upstream `PCMChunk` sizes vary — `MicrophoneSource` typically delivers ~4 800 frames per tap fire on macOS 14 hardware, while `ScreenCaptureKitSource` delivers ~960 frames per SCStream callback. Sizing by chunk count would give wildly different wall-clock retention windows per source. Sizing by wall-clock seconds requires a clock + per-chunk timestamps, which we have but adds complexity. Frame-count sizing is the cheapest invariant that produces predictable retention duration regardless of upstream chunking, and it's spec §4.2-faithful (the spec says "30 s ring", which is a duration, and frames at a known sample rate are equivalent to a duration).
- **Status:** Active.

## 2026-05-08 — Phase 2 commit 4: Sarvam streaming API contract (discovered via official samples)

- **Decision:** The Sarvam streaming Speech-to-Text contract — endpoint, auth, audio framing, and response shape — is locked to what the official Sarvam samples publish, not the illustrative example in spec §4.2 prior to this commit. Capturing here so we don't re-litigate when commit 5's `SarvamProvider` is wired.
- **Endpoint** (transcription, not translation): `wss://api.sarvam.ai/speech-to-text/ws?language-code=<code>&model=<model>` — e.g. `language-code=en-IN`, `model=saarika:v2.5`. The translation endpoint at `wss://api.sarvam.ai/speech-to-text-translate/ws/{key}` is a separate path with a different auth scheme; we don't use it because we want transcript-fidelity (Devanagari for Hindi speech) rather than English translation.
- **Auth:** `api-subscription-key: <key>` header on the WebSocket upgrade `URLRequest` (the form supported by the published Python sample). The browser-friendly form is the WebSocket subprotocol `api-subscription-key.<key>`; we use the header form because `URLSessionWebSocketTask` accepts custom headers natively.
- **Audio framing on the wire:** JSON message per chunk, audio is base64-encoded inside the JSON — **not** raw binary frames as the earlier plan assumed.
  ```json
  {"audio": {"data": "<base64 of raw 16-bit PCM>", "encoding": "audio/wav", "sample_rate": 16000}}
  ```
  Chunk cadence ~100 ms (3 200 bytes per chunk at 16 kHz Int16 mono) per the official samples; we'll send what `PCMChunk` carries (~6–10 ms per chunk from upstream sources) since Sarvam's server handles aggregation.
- **Server response shape** (from the published HTML sample, `html-scripts/stt.html`):
  ```json
  {
    "type": "data",
    "data": {
      "request_id": "<id>",
      "transcript": "<text>",
      "language_code": "en-IN",
      "metrics": {"audio_duration": <seconds>, "processing_latency": <seconds>}
    }
  }
  ```
  The published samples don't show separate interim/final events — every emitted message is `type=="data"` with a complete transcript chunk. **Whether Sarvam streaming has an interim/final distinction is unresolved** until commit 5's live probe; if the probe shows no interim events, the LiveMeetingView "interim italics" UX is dropped and we render each `data` message as a finalized line directly.
- **Diarization:** **Not supported on streaming** — Sarvam diarizer is batch-only ("Batch API only: Speaker diarization is only available through the Batch API, not the REST or Streaming APIs"). This forces Path B (next entry).
- **Streaming STT does not have an explicit `diarization` query parameter, an `interim_results` parameter, or a `vad_events` parameter** in the form the spec previously claimed. The optional params we observed are `language-code`, `model`, and `high_vad_sensitivity`.
- **Status:** Active. Commit 5's live probe replaces the static fixture in `ExecaTests/Fixtures/sarvam-data-sample.json` with real wire output and may add interim/error variants if they exist.

## 2026-05-08 — Phase 2 commit 4: Path B — post-hoc batch diarization (supersedes mic-diarization streaming)

- **Decision:** Diarization is post-hoc, batch-driven, not streaming. At `stopMeeting`, execa submits the saved per-stream WAVs to Sarvam's batch Speech-to-Text API with `with_diarization=true`. Live transcript ships during the meeting without speaker labels — every mic event collapses to `displayName` (fallback `"You"`); every system event collapses to `"Remote"`. Speaker IDs come from the batch result and get reflected via a post-hoc rename UI in the meeting detail view.
- **Supersedes:** the 2026-05-08 entry "Phase 2: mic stream is now diarized too." That decision assumed Sarvam streaming supported `diarization=true`; the commit 4 discovery probe (per the entry above) found it does not. The streaming-mic-diarization plan is dead; the *intent* (multi-speaker in-room hybrid meetings get correctly labeled) is preserved via the batch path.
- **Auto-run toggle:** A new setting `auto_diarization` (default: on) governs whether the batch fires automatically at `stopMeeting`. When off, the batch doesn't run automatically; the user can trigger it via a "Re-run diarization" action in the meeting detail UI on demand. The toggle gates the auto-trigger only, not the capability — manual re-run is always available regardless of toggle state.
- **Retry:** Batch failures (network, API error, rate limit) surface as a retry affordance in the meeting detail view. The "Re-run diarization" action is the same code path; the user can trigger it any time.
- **Race condition** (batch returns while the live meeting is still open or while the user is editing the transcript): a non-blocking banner appears — "Speaker labels available — apply?" with Apply / Dismiss. Don't auto-merge — the user keeps control. Dismissing leaves the action available from the meeting detail view (same entry point as manual re-run).
- **Default labels post-batch:** When the batch returns and the rename UI runs, defaults seeded from each batch-derived speaker are: `(mic, 0)` → `displayName`; `(mic, N≥1)` → `"In-room \(N+1)"`; `(system, N)` → `"Speaker \(N+1)"`. Calendar-attendee seeding is a future improvement (requires calendar integration not yet in scope).
- **Phase carve-up:**
  - **Phase 2 ships now**: live streaming with single-label-per-stream (mic→displayName, system→"Remote"); the missing-Sarvam-key gate; the wizard STT step; LiveMeetingView; reconnect UX. *Does not* ship batch kickoff or rename UI — those land in Phase 3.
  - **Phase 3 lands**: Sarvam batch API client; auto-trigger at `stopMeeting` (gated by the toggle); batch result storage; rename UI in the meeting detail view; the Apply / Dismiss banner; the "Re-run diarization" action; the `auto_diarization` setting key. Phase 3's BUILD_PLAN scope already covers "rename, merge, split"; this just expands it to include the batch-integration that produces the IDs being renamed.
  - **Phase 5+** (when the meeting detail view UI ships): the rename UI gets its proper home; the calendar-attendee seeding may attach if calendar integration lands.
- **Status:** Active.

## 2026-05-09 — Phase 3 commit 2: Sarvam batch STT API contract (discovered via probe)

- **Decision:** The Sarvam batch Speech-to-Text contract for diarized transcription is locked to what `scripts/sarvam-batch-probe.swift` exercised end-to-end against the live API on 2026-05-09. The lifecycle is six steps; capturing here so commit 3's `SarvamBatchClient` doesn't re-discover.
- **Endpoints (all under `https://api.sarvam.ai`):**
  - `POST /speech-to-text/job/v1` — init. Body: `{"job_parameters": {"model": "saarika:v2.5", "language_code": "en-IN", "with_diarization": true, "input_audio_codec": "wav"}}`. Response 202: `{"job_id": "<id>", "storage_container_type": "Azure_V1", "job_state": "Accepted", ...}`. **Note:** the legacy `/speech-to-text/job/init` alias accepts a flat body (no `job_parameters` wrapper) and silently drops job params — the resulting job stays at `total_files=0` forever. The probe's first pass hit this trap; do **not** use `/init`.
  - `POST /speech-to-text/job/v1/upload-files` — request presigned PUT URLs. Body: `{"job_id": "<id>", "files": ["mic.wav", "system.wav"]}`. Response 200: `{"upload_urls": {"<filename>": {"file_url": "<presigned-PUT-url>"}}, ...}`. The presigned URLs are short-lived Azure Blob SAS URLs (note: `Azure_V1` container type uses per-file blob URLs, not the directory SAS the legacy `/init` returns).
  - `PUT <presigned-PUT-url>` — upload the WAV directly to Azure Blob with `x-ms-blob-type: BlockBlob` header and `Content-Type: audio/wav`. Response 201.
  - `POST /speech-to-text/job/v1/{job_id}/start` — empty JSON body `{}`. Response 200: `{"job_state": "Pending", "total_files": <N>, ...}`.
  - `GET /speech-to-text/job/v1/{job_id}/status` — poll. Response 200 with `job_state` of `Accepted` / `Pending` / `Completed` / `Failed`. Diarized 3-second sample completed in ~2 s after `/start` in the probe; longer files will scale linearly. Recommended poll interval ~3 s. Status payload includes `job_details[].outputs[].file_name` (e.g. `"0.json"` for the first input file) — these are the result-file names to download.
  - `POST /speech-to-text/job/v1/download-files` — request presigned GET URLs for results. Body: `{"job_id": "<id>", "files": ["0.json"]}`. Response 200: `{"download_urls": {"0.json": {"file_url": "<presigned-GET-url>"}}, ...}`.
  - `GET <presigned-GET-url>` — fetch the actual transcript JSON.
- **Result JSON shape** (per file, captured in `Execa/ExecaTests/Fixtures/sarvam-batch-result-sample.json`):
  ```json
  {
    "request_id": "<id>",
    "transcript": "<full-text>",
    "timestamps": null,
    "diarized_transcript": {
      "entries": [
        {"transcript": "...", "start_time_seconds": 0.01, "end_time_seconds": 3.29, "speaker_id": "0"}
      ]
    },
    "language_code": "en-IN",
    "language_probability": null
  }
  ```
  Key surprises vs. the spec's prior assumption:
  - **`speaker_id` is a string** (`"0"`), not an integer. The parser converts to `Int` at the boundary; non-numeric IDs would fail loudly rather than silently misattribute.
  - **Times are floating-point seconds** (`start_time_seconds`, `end_time_seconds`), not integer milliseconds. The parser multiplies by 1000 and rounds to match the existing `transcript_segments.start_ms / end_ms` schema.
  - **No `language_code` per entry** — only at the top level. `BatchSegment.languageCode` therefore copies the top-level value into each segment in the parsed result.
  - The flat `transcript` field at the top level is the un-diarized concatenation; `diarized_transcript.entries[]` is what the swap logic uses.
- **Auth:** `api-subscription-key: <key>` header on every Sarvam endpoint (not the presigned Azure URLs — those carry their own SAS signature in the query string). Same key as the streaming client.
- **Status:** Active.

## 2026-05-09 — Phase 3: batch result is authoritative — replace, don't merge

- **Decision:** When a Sarvam batch diarization result arrives,
  `DiarizationService.swapInDatabase` DELETEs all existing `speakers` rows for the meeting (cascading to `transcript_segments` via the FK ON DELETE CASCADE), then INSERTs fresh rows from the batch result with Path B default labels. There is no reconciliation between streaming-time text and batch-time text. The streaming transcript stays in the in-memory `TranscriptStore.lines` until the user closes the live window; from then on, the DB is the canonical store.
- **Alternatives considered:** (a) Merge — match streaming segments to batch segments by overlapping `(start_ms, end_ms)` ranges, preserving any user edits (renames, splits) made mid-meeting. (b) Replace.
- **Why (b):** Merge sounds appealing but the implementation cost is real and the user value is low. Streaming-time text and batch-time text frequently disagree on token boundaries, capitalization, and word choice — Sarvam's batch model has access to the full audio at once and routinely produces a *better* transcript than the chunk-at-a-time streaming pipeline. A merge would have to either (i) keep both versions, doubling DB rows and confusing the UI, or (ii) pick one per segment, requiring a heuristic for "which version is canonical here" that nobody would understand. Replace is the simplest model: the user briefly sees streaming text mid-meeting, then sees the cleaner batch text in the meeting detail view. Single user-visible exception: the mid-meeting `(mic, raw_speaker_id=0)` rename is preserved across the swap (separate DECISIONS entry below) — the ~80% case where this matters most.
- **Status:** Active.

## 2026-05-09 — Phase 3: mic raw_speaker_id=0 rename preserved across batch swap (Decision 17)

- **Decision:** Before the swap DELETEs old `speakers` rows for the meeting, `DiarizationSwap.fetchPreservedMicZeroLabel` captures the current `(mic, raw_speaker_id=0)` row's `display_label` if (and only if) it differs from the current `displayName` setting. After the swap INSERTs the new `(mic, raw_speaker_id=0)` row with the default `displayName` label, the captured value is reapplied via a single UPDATE.
- **Alternatives considered:** (a) Preserve nothing — every swap follows the static defaults. (b) Preserve the mic-0 rename only. (c) Preserve all renames across all `(source, raw_speaker_id)` pairs by snapshotting the entire pre-swap label map, replaying overrides post-swap.
- **Why (b):** (a) is what the Phase 2 code did, and it's painful — a user who renames "You" to "Anand" mid-meeting watches that rename get wiped on stop, with no warning. (c) preserves more user intent but adds complexity for a vanishing return: the mic-0 rename is the ~80% case (it's the user's own voice; they're motivated to label it correctly). Other renames mid-meeting are rare (the user typically waits for the multi-speaker labels to land via batch before renaming additional clusters). The pre/post-swap label maps for non-mic-0 rows would also be inconsistent with the new batch-derived speaker IDs, requiring a fuzzy-match heuristic that adds bug surface. (b) is one comparison and one UPDATE, covers the common case, and the user can always rename additional speakers post-batch in the meeting detail view.
- **Implementation:** `DiarizationSwap.fetchPreservedMicZeroLabel` returns nil if (i) no `(mic, raw_speaker_id=0)` row exists pre-swap, (ii) its label equals `displayName` (no rename happened), or (iii) its label is empty. Otherwise returns the captured value, which the swap reapplies after the new row is inserted. Tested by `DiarizationServiceEdgeCaseTests.micZeroRenamePreservedAcrossSwap` (rename survives) and `DiarizationServiceEdgeCaseTests.micZeroDefaultLabelDoesNotOverridePathBSwap` (no override applied when value matched).
- **Status:** Active.

## 2026-05-09 — Phase 3: cross-source merge supported via `merged_into_speaker_id` with no source constraint

- **Decision:** `SpeakerLabelManager.merge(sourceSpeakerID:intoTargetSpeakerID:)` accepts any pair of speakers within one meeting regardless of `source` value — a `(mic, ...)` row can be merged into a `(system, ...)` row and vice versa. The FK `speakers.merged_into_speaker_id REFERENCES speakers(id) ON DELETE SET NULL` carries no `source`-constraint check, by design.
- **Why:** The Phase 1 closeout entry documents speaker bleed-through: when the user is on built-in speakers (no headphones), a remote person heard via the laptop's speakers gets re-captured by the mic. The same person then shows up as two separate speakers — one in the mic-batch result, one in the system-batch result — because Sarvam diarizes each WAV independently. The user needs to collapse them into one display label without forcing artificial within-source merging. Cross-source merge is the simplest model that supports this; the alternative (separate "cross-stream merge" UX) duplicates the merge code path for no gain.
- **Implementation:** `SpeakerLabelManager.merge` runs an existence + same-meeting guard, then UPDATEs `speakers.merged_into_speaker_id`. Idempotent: a re-merge with the same `(source, target)` pair is a no-op (the UPDATE is value-stable). `SpeakerQueries.effectiveLabel` and `SpeakerQueries.talkTimeAggregated` walk the alias chain so views render the merge target's label and sum talk-time across both clusters. `SpeakerSidebar`'s merge picker (commit 6) shows ALL meeting speakers from both sources in one list with a small `· mic` / `· system` source caption to disambiguate.
- **What does NOT apply across sources:** transcript segments stay attached to their original speaker — only the display chain changes, not the FK. New segments from streaming continue to attach to their original speakers row even after merge. No row-update churn.
- **Tested by:** `SpeakerLabelManagerMergeSplitTests.mergeCrossSourceWorksAndAggregatesTalkTime` (mic merged into system, talk-time aggregates across both, alias's own key disappears from the aggregated map).
- **Status:** Active.

## 2026-05-09 — Phase 3: voice-sample playback rule for merged speakers (Revision 5)

- **Decision:** When the user clicks "Voice sample" on a `speakers` row that has been merged via `merged_into_speaker_id`, `SpeakerVoiceSamplePlayer.windowToPlay` walks the alias chain to the canonical (un-merged) speaker via `SpeakerQueries.canonicalSpeakerID`, fetches **the canonical speaker's** most-recent finalized `transcript_segments` row, and plays a 3 s window ending at that segment's `end_ms`. The audio bytes are sourced from the WAV named by **the segment row's** `source` (mic.wav or system.wav) — NOT the canonical speaker row's `source`. After a cross-source merge the two can differ; the segment-row source is what the audio file reflects.
- **Alternatives considered:** (a) For a merged alias, play the alias row's own segment(s) (which don't exist post-merge — segments are reattached only on split, not on merge — so this would always return no-data). (b) Play a fixed segment (e.g. always pick the first segment for the canonical speaker). (c) Walk the alias and pick the canonical's most-recent segment (chosen).
- **Why (c):** "Most-recent" tracks user intent — they're typically reviewing the latest evidence for a label decision. Mid-meeting the player is gated off entirely (Decision 5 — WAVs are still being written) so this only runs post-stop. Tested by `SpeakerVoiceSamplePlayerTests.mergedSpeakerWalksAliasChain` and `.crossSourceMergeSourcesBytesFromSegmentSource`. Source-clamp and start-at-0 edge cases tested by `.clampsStartAtZeroForVeryEarlySegments`.
- **Status:** Active.

## 2026-05-09 — Phase 3: post-batch announcement is single-button "Got it" toast (Revision 1)

- **Decision:** When the diarization status flips to `.completed` while `MeetingDetailView` is on screen, a single-button "Got it" announcement banner appears at the top of the view: green checkmark + "Speaker labels are ready." + Got it button. Auto-dismisses after 5 s if the user doesn't interact. There is no "Apply" or "Dismiss" choice — Decision 2's authoritative-replace semantics make the swap automatic and irreversible (the DB is already updated with the new labels by the time the announcement fires), so there's nothing to apply or dismiss.
- **Alternatives considered:** (a) Two-button "Apply / Dismiss" banner — original Phase 3 plan, before the round-2 simplification round. (b) No banner — DB just updates silently. (c) Single-button "Got it" announcement (chosen).
- **Why (c):** (a) implies the user has a meaningful choice to make, but they don't — Decision 2 means the swap already ran. Putting an "Apply" button on a fait accompli is misleading. (b) is too quiet — without an indication, the user might miss that batch labels arrived (the speaker list quietly changing while they were reading the transcript is jarring). (c) splits the difference: clear acknowledgement, no false agency, auto-dismiss so it never blocks.
- **Implementation:** `MeetingDetailView.showCompletedAnnouncement` boolean flips to `true` on the `.onChange` of `DiarizationStatusStore.status(forMeetingID:)`; a Task sleeps 5 s then flips back. Banner uses `Color.green.opacity(0.08)` background with the checkmark icon.
- **Status:** Active.

## 2026-05-09 — Phase 3 follow-up: per-source 0-indexed speaker renumbering at swap (BUG 8)

- **Decision:** When `DiarizationSwap.swapInDatabase` materializes `speakers` rows from a Sarvam batch result, it renumbers the per-source speaker IDs to a 0-indexed sequence — sorted by earliest segment `start_ms`, with the original Sarvam ID as a tie-breaker. The DB invariant is "the first speaker on this source has `raw_speaker_id=0`," regardless of what Sarvam called the cluster internally. `transcript_segments.speaker_id` rows are inserted with the renumbered values via the same `speakerIDMap` (which is keyed by the original Sarvam ID for lookup) so the segment FKs land on the right rows.
- **Why:** Manual smoke Test 1 surfaced **BUG 8**: a single-mic-speaker meeting came back from Sarvam's batch as `speaker_id=1` (not 0). The Phase 3 commit-4 swap stored that value verbatim as `raw_speaker_id=1`, which (a) broke the default-labeling rule (the row got "In-room 2" instead of `displayName`), and (b) silently broke Decision 17's mic-rename preservation — the preservation code looked for `(mic, raw_speaker_id=0)` and found nothing, so the captured rename was discarded. Sarvam doesn't document the 0-indexing contract and clearly doesn't honour it. Renumbering at our boundary turns this into a stable invariant we control.
- **Implementation:** `DiarizationSwap.insertOneSource(input:map:in:)` builds a `firstSeen: [Int: Int]` map of `sarvamID -> earliestStartMs`, sorts by `(earliestStartMs, sarvamID)` for determinism, and emits 0-indexed rows in that order. Decision 17's preservation UPDATE in `swapInDatabase` no longer looks up the row via the `speakerIDMap` (which is keyed by Sarvam ID); it now UPDATEs by `(meeting_id, source='mic', raw_speaker_id=0)` directly so it always finds the post-renumbering mic-0 row.
- **Tested by:** `DiarizationServiceRenumberingTests.batchSpeakerIDsRenumberedTo0Indexed` (mic [3,7,12] → [0,1,2], system [1,5] → [0,1] in first-seen order with segments still attaching to the correct renumbered FKs); `decision17PreservationWithNonZeroIndexedBatch` (the exact BUG 8 repro: Sarvam returns `speaker_id=5` for a single mic speaker, post-swap `(mic, 0)` exists with the preserved rename); `renumberingIsStableForTiedStartTimes` (overlapping start_ms: tie-break on Sarvam ID ascending so the assignment is deterministic).
- **Status:** Active.

## 2026-05-09 — Phase 3 follow-up: live label propagation on rename / merge / split (BUG 7)

- **Decision:** `AppCoordinator` exposes `renameSpeaker`, `mergeSpeakers`, and `splitSegment` wrappers that call `SpeakerLabelManager` AND, on success, walk `TranscriptStore.lines` to update any in-memory line attributed to the affected speaker (matched via the new `TranscriptLine.databaseSpeakerID` field, set at line creation in `applyInterim` / `applyFinal`). UI call sites use the wrappers; calling `speakerLabelManager` directly is reserved for tests. SwiftUI's `@Observable` invalidation on `TranscriptStore.lines` re-renders the affected rows.
- **Why:** Manual smoke Test 1 surfaced **BUG 7**: the user single-clicked rename `(mic, 0)` from `displayName` to "Test Anand", the DB row updated correctly, but the sidebar and past transcript turns kept showing the old label until the next `.final` event arrived (which retriggered a per-line label fetch). The Phase 3 plan's risk note treated this as a brief flicker; in practice it's a permanent cache miss because `TranscriptLine.speakerLabel` is captured-by-value at creation time. The fix moves the propagation from "happens on next final" to "happens immediately on rename" so the user sees the new label without speaking again.
- **Alternatives considered:** (a) Don't cache `speakerLabel` on `TranscriptLine`; resolve via lookup at render time. (b) Cache + propagate on edit (chosen).
- **Why (b):** (a) is architecturally cleaner — no cache drift possible — but it forces the SwiftUI render path to query something (in-memory or DB) on every line, every render, for every meeting. The render-time-resolution path also doesn't compose cleanly with `LiveMeetingView`'s `@Observable`-driven re-render — the lookup function would need its own observation to invalidate. (b) keeps the existing line-as-display-state contract intact and adds three small mutators (`applyRename`/`applyMerge`/`applySplit`). Trade-off: the rename/merge/split paths must remember to call the propagation wrapper (instead of `speakerLabelManager` directly). Code review enforcement; the regression tests in `TranscriptStoreLabelPropagationTests` cover the propagation behaviour itself.
- **Tested by:** `TranscriptStoreLabelPropagationTests` (5 tests): rename updates all matching lines; rename leaves other speakers untouched; merge substitutes target's label on alias's lines; split retargets `databaseSpeakerID` and updates label on the matching segment line only; rename on unknown speaker is a no-op.
- **Status:** Active.

## 2026-05-09 — Phase 3: per-stream batch submission (mic.wav + system.wav as two calls)

- **Decision:** `DiarizationService.runForMeeting` submits `mic.wav` and `system.wav` to the Sarvam batch endpoint as two **separate** jobs (concurrently, two calls), not as a single job containing both files, and not against the downmixed `master.flac`. Each per-stream result feeds into the DB with `source` already known per file.
- **Alternatives considered:** (a) Submit `master.flac` once and let Sarvam diarize the mixed audio. (b) Submit `mic.wav` + `system.wav` together in one job with two input files. (c) Submit per-stream as two jobs.
- **Why (c):** Submitting `master.flac` (option a) loses mic-vs-system attribution that the existing `(meeting_id, source, raw_speaker_id)` data model relies on — Sarvam would emit globally-numbered speaker IDs with no way to recover which physical input each ID came from. Submitting both files in one job (option b) works on the wire (the v1 API supports multiple files per job), but Sarvam's batch returns one independent diarization per file — speaker `"0"` in `mic.wav`'s result has no relationship to speaker `"0"` in `system.wav`'s result either way, so we'd still need to keep them separate in code. Two jobs (option c) is the simplest mental model: each call's `speakerID` namespace is implicitly per-source, the swap logic can iterate over `(source, BatchSegment)` pairs without coordination, and a partial failure (one source succeeds, the other fails) is straightforward to surface independently. Cost: two API calls per meeting instead of one. The cost is small relative to the typical 30+ second batch processing time.
- **Status:** Active.

## 2026-05-10 — Phase 3.5: deterministic post-batch speaker bleed-through dedup

- **Decision:** When the user runs a meeting on built-in speakers (no headphones), the laptop's speakers play remote audio into the room and the mic re-captures it; the same remote voice gets transcribed both as a system-side `Speaker N` AND a mic-side `In-room N+1`. Phase 3.5 runs a deterministic post-batch dedup pass that flags mic-side segments mirroring a system-side segment in time AND text, and soft-deletes them via the new `transcript_segments.deduped_against_segment_id` column (v4 migration). All rendering queries filter `WHERE deduped_against_segment_id IS NULL`. The `speakers` rows themselves stay in the DB; they're filtered out of the sidebar / detail-view at the view layer via `SpeakerQueries.visibleSpeakers`'s `EXISTS` subquery so orphaned mic speakers don't show up.
- **Algorithm:** for each mic-side segment M, find any system-side segment S with `timeOverlapFraction(M, S) ≥ 0.5` (overlap relative to `min(mic_dur, system_dur)`) AND `jaccardTextSimilarity(M.text, S.text) ≥ 0.6` (lowercased + unicode-tokenized word sets). Skip pairs where either side is < 1 s, has confidence < 0.6 (NULL confidence proceeds), or has empty text. First match wins; mic stops scanning after one match for stable audit pointers. Direction is one-way: mic flagged as bleed of system, never the reverse.
- **Alternatives considered:** (a) Acoustic Echo Cancellation via `kAUVoiceProcessingIO` — the thorough fix; rejected for Phase 3.5 because it's a 1–2 week audio-stack restructure that interacts with `AVAudioEngineConfigurationChange`, adds 20–40 ms latency, and may conflict with concurrent SCK capture (per Phase 1 closeout). (b) Hard delete deduped rows + separate `dedup_log` table — rejected because the column-on-soft-deleted-row design provides equivalent audit visibility (`SELECT … WHERE deduped_against_segment_id IS NOT NULL`) for less code. (c) Bidirectional dedup (system flagged as bleed of mic too) — rejected because the user's voice doesn't loop back through system audio in normal operation, and bidirectional dedup risks deleting legitimate mic speech.
- **Why (deterministic dedup):** Operational alternative to AEC for the executive-meeting use case where headphones aren't always worn. Single module hooked into `DiarizationService.runForMeeting`. 1–2 days to ship vs 1–2 weeks for AEC. Conservative thresholds avoid false positives at the cost of occasional false negatives (un-deduped duplicates surface; user re-runs).
- **Operational impact:** Supersedes the operational consequence of the Phase 1 closeout headphones-assumption note. The parked-AEC entry is not reversed — AEC may still be the right choice in a future phase if real meetings surface bleed patterns the dedup misses. Phase 3.5 is the "good enough now" step.
- **Settings:** `auto_speaker_bleed_dedup` (default `true`). Reachable via direct DB edit until Phase 5's Settings UI ships. Disabling skips the dedup pass entirely; both sides remain visible (Phase 3 behavior).
- **Two-write design:** swap and dedup run in separate `database.queue.write` blocks, not the same transaction. There's a millisecond-scale crash window between the two writes; recovery is via Re-run diarization. Trade-off documented inline in `DiarizationService.runForMeeting` so future maintainers preserve the design intentionally.
- **Re-run semantics:** Re-run diarization re-applies dedup against the freshly-swapped state. Previous dedup decisions are not preserved across re-run.
- **Known limitation:** if the device owner verbatim repeats remote audio (rare), mic-0 segments may be deduped and the mic-0 speaker becomes orphaned. User can disable `auto_speaker_bleed_dedup` for that meeting and Re-run diarization to recover. Conservative thresholds (1 s min duration, 0.6 min confidence) make this rare in practice.
- **Tested by:** `Phase35SchemaTests` (column + ON DELETE SET NULL + settings default), `SpeakerBleedDeduperTests` (18 pure-function tests covering both threshold boundaries + every early-skip filter + tokenizer unicode handling), `SpeakerBleedDedupIntegrationTests` (6 DB-driven tests: mirrored meeting deduped, paraphrase preserved, single-source no-op, empty no-op, flag-off bypass, orphan mic speaker hidden via `visibleSpeakers`).
- **Status:** Active. Algorithm details superseded by Phase 3.5b v2 entry below; the soft-delete + view-filter design remains unchanged.

## 2026-05-11 — Phase 3.5b: v2 dedup algorithm — containment + stemming + concatenation + cross-validation

- **Decision:** The Phase 3.5 dedup pass keeps its soft-delete-via-audit-column design and its view-layer orphan-speaker filter, but the scoring function is replaced. Jaccard 0.6 over raw tokens (v1) → containment 0.75 over Porter-light-stemmed tokens (v2), plus two new passes: a concatenation pre-pass that scores groups of consecutive same-speaker mic fragments as one unit, and a cross-validation post-pass that promotes the unflagged segments of mic speakers who are already ≥ 80% flagged (with ≥ 3 absolute flagged segments). v1 is retained as a flag-fallback under `bleed_dedup_algorithm_version = "v1"`; default is `"v2"`.
- **Why:** Phase 3.5 manual smoke surfaced a real algorithmic weakness: when the mic captures a 30-token fragment of a 90-token system segment (the most common bleed pattern in practice), Jaccard = 30/90 = 0.33, well below the 0.6 threshold. v1 correctly skipped per its rule but left a visible duplicate mic-side speaker in the meeting detail view. Containment (`|mic ∩ system| / |mic|`) hits 1.0 on that same pair — it's the right metric for the "mic is a fragment of system" case that bleed produces.
- **Algorithm pass order:** concatenation pre-pass → containment pairwise (excluding pre-pass-flagged) → cross-validation speaker-level promotion. Each pass runs once per dedup invocation; the order is fixed because each later pass excludes already-flagged segments.
- **Thresholds (locked):**
  - `minContainment: 0.75` — chosen tighter than v1's 0.6 jaccard because containment is a stricter measure of real bleed. Boundary tests at 74% / 75% pin the contract.
  - Concatenation: group size ≥ 2, total duration ≥ 1 s, min non-NULL confidence ≥ 0.6, group entirely contained in one system segment. Tie-break on system: longest first, lowest id second.
  - Cross-validation: flagged ratio ≥ 0.8 AND flagged count ≥ 3. Target system speaker chosen by (count, cumulative containment, lowest id). Audit FK on promoted segments points at the nearest-neighbor system segment by `startMs`.
- **Porter-light stemmer:** six rules in precedence order (ies→y, ied→y, ing→, ed→, es→, s→) with input-length guards. ASCII-only — Devanagari and other non-ASCII tokens pass through untouched, preserving the existing `tokenizeHandlesDevanagari` invariant. Min-input lengths (5 or 7) protect short words: "his", "was", "yes", "ring", "fed", "bed", "uses" all stay unchanged. The ruleset has known imperfections ("races" → "rac" via es-rule), accepted as the Porter-light trade-off — a full stemmer requires word-list lookup we're not adding.
- **v1 flag-fallback rationale:** if v2 over-dedupes in real meetings (false positives the synthetic tests miss), the user can `UPDATE settings SET value='v1' WHERE key='bleed_dedup_algorithm_version'` and Re-run diarization to revert. A/B regression escape hatch with no code change required. v1 path is fully preserved and tested.
- **Code shape:** `pairsToDedup(segments:version:)` dispatches on the `BleedDedupAlgorithmVersion` enum. v1 logic lives in `SpeakerBleedDeduper.pairsToDedupV1` (unchanged). v2 logic lives in `SpeakerBleedDedupV2.swift` as an extension on `SpeakerBleedDeduper` so the main file stays under the file-length cap. `DedupPair` audit struct carries `containment`, `jaccard`, and `promotionReason` (`.pairwise` / `.concatenation` / `.speakerPromotion`) for in-memory debugging; only the FK is persisted in the DB.
- **Flag interaction:** `auto_speaker_bleed_dedup` decides WHETHER dedup runs (Phase 3.5); `bleed_dedup_algorithm_version` decides WHICH algorithm. Orthogonal. Both default-on / default-v2.
- **Tested by:** `SpeakerBleedDeduperTests` (38 pure-function tests including the v1→v2 regression pair pinning the 30/90-token failure mode), `SpeakerBleedDedupV2ConcatenationTests` (8 pre-pass tests including alternating-speakers, sub-second-total, low-confidence, multi-system span, longer-system tie-break, equal-length-tie lowest-id, orchestrator pre-pass+pairwise sequencing), `SpeakerBleedDedupV2CrossValidationTests` (6 post-pass tests including 4-of-5 promotion, 2-of-5 / 3-of-4 rejection, min-flagged floor, nearest-neighbor audit FK, lowest-id tie-break), `SpeakerBleedDedupIntegrationTests` (now 8 DB-driven tests covering both the concat and cross-validation end-to-end paths).
- **Phase 3.5 entry above remains Active for the soft-delete / view-filter design; the algorithm thresholds are operationally superseded by this entry.** The parked-AEC entry from Phase 1 closeout is unchanged — AEC may still be the right choice in a future phase if real meetings surface bleed patterns v2 misses.
- **Status:** Active. Algorithm details superseded by the Phase 3.5c entry below for the merge-aware scoring + auto-rerun semantics; the threshold values and pass ordering carry forward unchanged.

## 2026-05-12 — Phase 3.5c: merge-aware dedup with auto re-run on merge/split

- **Decision:** The Phase 3.5b v2 algorithm becomes merge-aware: pairwise + concatenation pre-pass + cross-validation all score the mic side against the **effective** system speaker's combined text (constituent segments joined in `startMs` order), where the effective speaker is `COALESCE(speakers.merged_into_speaker_id, speakers.id)`. The dedup pass becomes reset-first — at the top of `SpeakerBleedDeduper.dedup`, every `transcript_segments.deduped_against_segment_id` for the meeting is set NULL, then the algorithm re-derives state against the current topology. `AppCoordinator.mergeSpeakers` and `splitSegment` invoke `DiarizationService.rerunDedupForMeeting` as their final step, so the user's manual topology fix immediately propagates to the dedup state without a manual Re-run. Rename is unchanged (label-only, topology untouched).
- **Why:** Phase 3.5b manual smoke surfaced a real interaction gap. Sarvam's batch diarization over-segments one voice into multiple system speakers in some meetings; the mic-side bleed of that voice splits its matches across the over-segmented system speakers, none of which alone clears the cross-validation thresholds (the cumulative-containment-by-speaker math fails when the same person is spread across two speakers). Even after the user manually merges those system speakers, the dedup state was written at swap time against the unmerged topology — visible duplicates persisted in the meeting detail view until an explicit Re-run. Merge-aware scoring + auto re-run on merge makes the topology fix actually fix the rendering.
- **Algorithm shape — what changed:** `Segment.effectiveSpeakerID` is loaded via JOIN+COALESCE from `speakers.merged_into_speaker_id`. A new `EffectiveSystemSpeaker` aggregate carries the union segments, combined text (joined in `startMs` order), and time envelope. `buildEffectiveSystemSpeakers(systems:)` groups raw segments by `effectiveSpeakerID`. Pairwise + concat pre-pass + cross-validation iterate `[EffectiveSystemSpeaker]`. The audit FK still anchors on a specific `transcript_segments.id` — picked via `bestOverlapSegment` (highest time-overlap fraction; tie → longest, then lowest id) so the durable DB pointer survives a subsequent unmerge/re-split.
- **Reset-first contract:** `SpeakerBleedDeduper.dedup` now writes `UPDATE transcript_segments SET deduped_against_segment_id = NULL WHERE meeting_id = ?` at the very top of the function. The previous `WHERE deduped_against_segment_id IS NULL` filter on the load is gone — `loadSegments` now returns every final segment regardless of FK state. This makes the function idempotent under re-run: at swap time the reset is a no-op (fresh rows are already NULL); on a merge/split re-run, stale FKs from the previous topology get wiped before re-derivation against the new topology.
- **Single-hop alias resolution:** The dedup pass uses `COALESCE(s.merged_into_speaker_id, s.id)` — a single hop, not a recursive CTE. This matches the Phase 3 invariant that the UI merges `A → B` only when neither `A` nor `B` is itself an alias (`SpeakerLabelManager.merge` doesn't enforce this, but the sidebar's "Merge into…" affordance only offers visible non-alias speakers). If a future workflow lets aliases chain (`A → B → C`), the JOIN's COALESCE would resolve `A` to `B` instead of `C`. The defensive walking loop in `SpeakerQueries.canonicalSpeakerID` already handles chains for display-time concerns; the dedup pass would need a recursive CTE or a pre-pass that walks the chain into a temp `effective_id` column. Deferred — no chained-alias workflow exists yet.
- **Auto re-run hook:** `AppCoordinator.mergeSpeakers` and `splitSegment` call `diarization.rerunDedupForMeeting(meetingID:)` after the topology mutation + live `TranscriptStore` propagation lands. The hook is fire-and-await (the merge/split call doesn't return until the dedup re-derivation completes — single round trip from the user's perspective). The `auto_speaker_bleed_dedup` setting still gates everything: if dedup is disabled, the re-run returns early via the same guard as the swap-time invocation. `renameSpeaker` deliberately does NOT call the hook because rename is a label-only change with no topology impact.
- **Code shape:** algorithm body lives in `SpeakerBleedDedupV2.swift` (under the file-length cap thanks to extracting scoring primitives into `SpeakerBleedDedupScoring.swift` and cross-validation into `SpeakerBleedDedupV2CrossValidation.swift`). `DiarizationService.runDedupPass` was renamed to `rerunDedupForMeeting` (now internal) so the inline post-swap call site and the new topology-change hook share one entry point. `AppCoordinator.init` gained an optional `database:` parameter for test injection; production call sites keep their zero-arg shape via default `nil`.
- **Flag interaction:** unchanged from Phase 3.5b. `auto_speaker_bleed_dedup` gates WHETHER dedup runs (swap-time AND merge/split-time); `bleed_dedup_algorithm_version` picks WHICH algorithm. Both default-on / default-v2. Direct DB edit only until Phase 5's Settings UI ships.
- **Persisted state shape:** unchanged. The DB still only persists the `deduped_against_segment_id` FK; the `PromotionReason` (`.pairwise` / `.concatenation` / `.speakerPromotion`) lives in-memory inside `DedupResult.pairs` for in-process debugging.
- **Tested by:** `SpeakerBleedDedupV2MergeAwareTests` (6 tests: pairwise + concat + cross-val all respecting effective-speaker combined text; paraphrase-survives-under-merged-system-topology guard; swap-time behavior unchanged when no merges exist; reset-first wipes a stale FK before re-derivation); `SpeakerBleedDedupAutoRerunTests` (3 tests: merge fires the re-run hook + re-derives flagged; split removes a cross-val-promoted FK; rename does NOT fire the hook — proven by a deliberately wrong FK surviving the rename); `SpeakerBleedDedupRerunGuardTests` (2 tests: setting-off short-circuits the re-run; reset-first then re-derive heals a wrong FK). Total: 11 new + 6 amended tests on top of Phase 3.5b's coverage.
- **Phase 3.5 + Phase 3.5b entries above remain Active for everything they document; this entry only supersedes the algorithm-scoring topology and adds the auto-rerun hook. The parked-AEC entry from Phase 1 closeout is unchanged.**
- **Status:** Active.

---

## How to add an entry

When a new architectural decision is taken (or an existing one reversed):

1. Append a new section dated `YYYY-MM-DD`.
2. State the **Decision** in one or two sentences.
3. List **Alternatives considered** if the choice was non-obvious.
4. Capture **Why** in 2–4 sentences focused on the trade-off.
5. Set **Status:** Active / Superseded by <date> / Parked.
6. Reference the spec section if the decision is mirrored there.

Do not delete or edit previous entries.
