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
