# BUILD_PLAN.md

Phased delivery plan for **execa**. Each phase ends in a runnable, demoable build with explicit acceptance criteria. Do not merge across phase boundaries until the prior phase's criteria pass.

The full specification is in `meeting-app-spec.md`; locked-in architectural decisions are in `DECISIONS.md`. This file tracks *what we're doing now* and *what comes next*.

---

## Current status

**Pre-implementation.** The repo contains the spec (`meeting-app-spec.md`), `CLAUDE.md`, `DECISIONS.md`, and this file. No source code, no `Execa.xcodeproj`, no `Package.swift`. Next step: Phase 0.

---

## Phase 0 — Project scaffold and persistence

**Goal:** A signed-and-buildable empty `.app` with the Keychain wrapper, GRDB schema, settings store, and a hollow first-run wizard. Nothing records audio yet.

**Scope:**
- Xcode project at `Execa.xcodeproj` matching the layout in spec §9.
- SPM dependencies wired in: `GRDB.swift`, `KeyboardShortcuts`, `Yams`, `Sparkle`, `Sentry-Swift`.
- `Persistence/Database.swift` with all migrations from spec §7 (meetings, speakers, transcript_segments + FTS5, summaries, prompt_templates, settings).
- `Keys/KeychainStore.swift` — set/get/delete by `(service, account)` pair; service names follow `com.anandthakur.execa.<provider>`.
- `UI/SetupWizardView.swift` — empty step views (Permissions, STT keys, LLM keys, Display name). No validation logic yet, just navigation + persistence.
- `App/ExecaApp.swift` + `App/AppCoordinator.swift` skeletons.
- SwiftLint + SwiftFormat configs at repo root. Both must pass on the empty project.
- Sandbox entitlements file with the full list from spec §11.3 (audio-input, network.client, files.user-selected.read-write).
- `Info.plist`: `CFBundleDisplayName=execa`, bundle ID `com.anandthakur.execa`, all NS*UsageDescription strings drafted.

**Acceptance:**
- `xcodebuild -scheme Execa build` clean.
- `xcodebuild -scheme Execa test` passes (one round-trip test against `KeychainStore` and one against `Database` migrations).
- App launches, shows Setup Wizard, persists "display name" to settings table, exits cleanly.
- App is signed with the Apple Development cert via automatic signing using the configured Team ID. Developer ID Application setup, notarization, and `create-dmg` are deferred to Phase 7.

---

## Phase 1 — Audio capture and archival

**Goal:** Press a button, get a meeting recorded to FLAC. No transcription yet.

**Scope:**
- `Audio/ScreenCaptureKitSource.swift` — system audio via `SCStream` with `capturesAudio=true`, `excludesCurrentProcessAudio=true`.
- `Audio/MicrophoneSource.swift` — `AVAudioEngine` mic on macOS 14, prep `SCStream.captureMicrophone` path for macOS 15+ (feature-flagged).
- `Audio/AudioMixer.swift` — separate-stream archival to `mic.wav` and `system.wav`, plus a downmixed `master.flac`.
- Resampling pipeline to 16 kHz mono Int16, used downstream in Phase 2.
- Output device change handling — restart capture without ending the meeting.
- Permission flow integrated into Setup Wizard.
- Menu bar item with red-dot recording indicator.

**Acceptance:**
- Start a meeting from the menu bar; a `meetings/<id>/master.flac` (and `mic.wav`, `system.wav`) appears under the sandbox container.
- Hot-swap headphones (AirPods connect/disconnect) does not stop the recording.
- Disk-full path triggers a graceful pause with notification.

---

## Phase 2 — Sarvam streaming + live transcript

**Goal:** Live transcript renders during a meeting. No diarization labels yet beyond raw provider IDs; no router or failover yet.

**Scope:**
- `Transcription/TranscriptionProvider.swift` — protocol + normalized event types.
- `Transcription/SarvamProvider.swift` — WebSocket adapter, `language=hi-en`, interim + final events.
- `Transcription/TranscriptStore.swift` — in-memory rolling buffer + DB writeback on `is_final`.
- `UI/LiveMeetingView.swift` — interim italics, finalized normal weight; speaker prefix shows raw `Speaker N`.
- Auto-reconnect with exponential backoff; 30 s ring buffer flushed on reconnect.

**Acceptance:**
- Live transcript displays within 2 s of first speech.
- Network drop mid-meeting → banner appears, audio buffered, transcript catches up on reconnect.

---

## Phase 3 — Diarization labels and speaker management

**Goal:** Anonymous Speaker IDs become rename-able. Merge / split for diarizer errors.

**Scope:**
- `Diarization/SpeakerLabelManager.swift` — rename, merge, split; updates apply retroactively to past turns and forward to future turns from the same cluster.
- `UI/SpeakerSidebar.swift` — list of speakers with talk-time and 3-second voice-sample playback.
- "You" auto-labeling on the mic stream (always tagged as local user).
- DB writes go through the `speakers` table; the `(meeting_id, source, raw_speaker_id)` tuple is the stable key.

**Acceptance:**
- Rename a speaker mid-meeting → all past and future turns reflect the rename.
- Merge two speakers → both clusters point to the same `display_label`.
- Split → introduces a new `speakers` row and reassigns selected segments.

---

## Phase 4 — `LLMRouter` and on-demand summaries

**Goal:** "Summarize so far" and per-speaker summaries work end-to-end.

**Scope:**
- `LLM/LiteLLMConfig.swift` — Yams-based parser for the LiteLLM YAML schema.
- `LLM/LLMTransport.swift` — protocol with in-process and external-proxy implementations.
- `LLM/LLMRouter.swift` — alias resolution, retries, fallback chains, cost tracking, streaming.
- `LLM/Providers/` — Anthropic, OpenAI, Gemini adapters (Bedrock, Azure, Ollama deferred to Phase 6 if time).
- `Summaries/SummaryService.swift` with default conversation and per-speaker prompts.
- `UI` panel for streaming-token rendering of summaries.

**Acceptance:**
- "Summarize so far" produces a coherent summary with speaker attributions.
- "Summarize speaker X" filters and produces a contribution-focused summary.
- Anthropic 5xx triggers automatic fallback to OpenAI without UI error.
- LLM spend per meeting is recorded and visible in the History view.

---

## Phase 5 — MOM, prompt templates, History view

**Goal:** End meeting → MOM.md is written. Prompt templates are user-editable.

**Scope:**
- `Summaries/MOMService.swift` with placeholder substitution (`{{date}}`, `{{participants}}`, etc.).
- `prompt_templates` table populated with default templates ("Default", "1:1", "Vendor pitch").
- `UI/SettingsView/PromptsPane.swift` — CRUD for templates.
- `UI/MeetingHistoryView.swift` with FTS-backed search.
- MOM exported as Markdown to `meetings/<id>/MOM.md`.

**Acceptance:**
- "End meeting" produces a non-empty MOM.md matching the configured template's structural shape.
- History search returns hits across past meetings.

---

## Phase 6 — Deepgram adapter and `TranscriptionRouter`

**Goal:** Auto-failover when Sarvam misbehaves.

**Scope:**
- `Transcription/DeepgramProvider.swift`.
- `Transcription/TranscriptionRouter.swift` — error-rate window, failover decision, mid-meeting switch with speaker-ID reconciliation prompt.
- Settings → Transcription pane (provider override, language profile, glossary).

**Acceptance:**
- Simulated Sarvam failure (mock server) triggers transparent switch to Deepgram within 60 s.
- Speaker reconciliation prompt appears; confirming maps Sarvam Speaker N → Deepgram Speaker M correctly.

---

## Phase 7 — Distribution: notarization, Sparkle, polished wizard

**Goal:** A `.dmg` a fresh Mac can install, notarized, with auto-update.

**Scope:**
- `xcodebuild archive` → `notarytool submit` → `stapler staple` → `create-dmg` pipeline as a CI workflow.
- Sparkle EdDSA key generation, appcast feed, update endpoint.
- Setup Wizard polish: permission deep-links, key validators (`KeyValidators.swift`) running real test calls.
- `Telemetry/CrashReporter.swift` (opt-in MetricKit + Sentry, scrubbed).

**Acceptance criteria match spec §17 in full.**

---

## Cross-phase rules

- Each phase's PR description references the spec sections it implements.
- New decisions discovered during implementation get appended to `DECISIONS.md` before the PR merges.
- If a phase requires a non-sanctioned dependency, stop and propose it explicitly rather than silently adding it.
