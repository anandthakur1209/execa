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
