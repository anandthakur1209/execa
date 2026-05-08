# execa — macOS Granola-Equivalent

> Product name: **execa** (lowercase, as user-visible in dock and menu bar via `CFBundleDisplayName`).
> Xcode project / Swift module / app bundle: **Execa** (PascalCase, per Swift convention).
> Bundle identifier: **com.anandthakur.execa**.
> Apple Developer Team: personal (Anand Thakur).

**Version:** 0.1 (draft for implementation)
**Target OS:** macOS 14 (Sonoma) and later — required for `ScreenCaptureKit` system audio + microphone capture without third-party drivers.
**Author:** Anand
**Date:** 2026-05-05

---

## 1. Overview

A native macOS application that sits in the menu bar, records both microphone and system audio during any meeting (Zoom, Meet, Teams, FaceTime, in-person via mic), produces a real-time speaker-labeled transcript, lets the user generate on-demand summaries (whole conversation or per speaker) at any point, and produces a final configurable Minutes-of-Meeting (MOM) document when the meeting ends. All recordings, transcripts, and summaries are stored locally; only audio chunks (to STT) and transcript text (to the LLM router) leave the machine, and only while a meeting is being processed.

### 1.1 Capabilities (mapped to user requirements)

| # | Requirement | Component |
|---|---|---|
| 1 | Capture mic + system audio | `AudioCaptureService` (ScreenCaptureKit + AVAudioEngine) |
| 2 | Real-time transcription | `TranscriptionService` (Deepgram WebSocket streaming) |
| 3 | Speaker diarization tagged inline | Same stream, Deepgram `diarize=true`; speakers shown as `Speaker 0/1/...` and renamable mid-meeting |
| 4 | On-demand summaries (whole / per-speaker) | `SummaryService` → in-process `LLMRouter` (LiteLLM-compatible config) → configured LLM |
| 5 | Final MOM with configurable system prompt | `MOMService` → `LLMRouter`, system prompt stored in user settings, editable |

---

## 2. Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                       Execa.app (Swift)                   │
│                                                                     │
│  ┌──────────────┐   ┌───────────────────┐   ┌──────────────────┐   │
│  │  Menu Bar /  │   │  Meeting Window   │   │  Settings Window │   │
│  │  Hotkey UI   │   │  (live transcript)│   │  (LLM, prompts)  │   │
│  └──────┬───────┘   └────────┬──────────┘   └─────────┬────────┘   │
│         │                    │                        │            │
│         ▼                    ▼                        ▼            │
│  ┌────────────────────────────────────────────────────────────┐    │
│  │                   AppCoordinator (actor)                   │    │
│  └──────┬───────────────┬────────────────┬─────────┬──────────┘    │
│         │               │                │         │               │
│         ▼               ▼                ▼         ▼               │
│  ┌─────────────┐ ┌──────────────┐ ┌────────────┐ ┌──────────────┐  │
│  │AudioCapture │ │Transcription │ │  Summary   │ │  Persistence │  │
│  │   Service   │ │   Service    │ │  Service   │ │   (GRDB)     │  │
│  └──────┬──────┘ └──────┬───────┘ └─────┬──────┘ └──────┬───────┘  │
│         │ 16kHz PCM     │ JSON          │ Prompt        │ SQLite   │
└─────────┼───────────────┼───────────────┼───────────────┼──────────┘
          │               │               │               │
          ▼               ▼               ▼               ▼
  ┌───────────────┐ ┌────────────┐ ┌──────────────┐ ┌──────────────┐
  │ ScreenCapture │ │  Sarvam /  │ │  LLMRouter   │ │ ~/Library/   │
  │ Kit + AVFAudio│ │  Deepgram  │ │  (Swift,     │ │ Application  │
  │ (local)       │ │  WS (cloud)│ │  in-process) │ │ Support/...  │
  └───────────────┘ └────────────┘ └──────┬───────┘ └──────────────┘
                                          │
                                          ▼
                                   ┌──────────────┐
                                   │ Anthropic /  │
                                   │ OpenAI /     │
                                   │ Gemini / ... │
                                   └──────────────┘
```

### 2.1 Process model

- **Single Swift app** (menu bar + windows). No child processes, no Docker, no Python runtime — everything is Swift code in one signed executable. This is a deliberate decision to keep distribution simple (see §13).
- **In-process `LLMRouter`** that reads a LiteLLM-compatible YAML config and exposes the same OpenAI-shape API to the rest of the app via Swift function calls (no localhost HTTP hop needed). Power users who want the full LiteLLM admin UI / spend dashboard can point the app at an external LiteLLM proxy via Settings → Advanced → Router URL.
- **No backend service** of our own. STT goes directly from the Swift app to the active provider over WebSocket; LLM calls go through `LLMRouter`, which fans out to the configured provider over HTTPS.

---

## 3. Technology Choices (and why)

| Layer | Choice | Rationale |
|---|---|---|
| App framework | **Swift 5.10 + SwiftUI**, AppKit where SwiftUI is insufficient (status item, accessibility) | Native macOS, lowest-latency audio path, single-binary install, full ScreenCaptureKit access. |
| Audio capture | **ScreenCaptureKit** (system audio + per-app capture, mic capture from macOS 15+) and **AVAudioEngine** (mic on macOS 14, mixing/monitoring) | First-party, no virtual driver, per-app filtering, lowest latency. SCK on macOS 15+ can capture mic directly; on macOS 14 we use AVAudioEngine for mic. |
| Real-time STT + diarization (default) | **Sarvam Saaras V3** streaming over WebSocket, with `diarization=true` | Purpose-built for Indic + Hinglish. Trained on 1M+ hours including heavy code-mixed audio (Hindi↔English mid-sentence). Streaming-first architecture, time-to-first-token <150 ms, native real-time diarization, 22 Indian languages + English, automatic language detection. Strongest available choice for Reliance-context meetings where speakers switch between Hindi and English freely. |
| STT alternative — English-heavy / global meetings | **Deepgram Nova-3 multilingual** (`diarize=true`, `language=multi`) over WebSocket | Mature, very low-latency (median inference ~40× faster than peer ASR with diarization), covers 10 code-switching languages including Hindi (≈27 % WER reduction vs Nova-2). Better choice when most participants are speaking English or when Sarvam is unreachable. Wired in behind the same `TranscriptionProvider` protocol. |
| STT alternative — extra accuracy fallback | **Soniox** or **AssemblyAI Universal-3 Pro Streaming** | Soniox: also strong on Hinglish mid-sentence switches, WebSocket streaming, diarization. AssemblyAI: stronger accuracy in noisy English (10.1 % DER improvement, 30 % noise robustness) but Hindi support is weaker. Both implemented as adapters; user picks in Settings. |
| LLM routing | **In-process Swift `LLMRouter`** that reads a **LiteLLM-compatible YAML config** | Gives us everything the user asked for from "a router like LiteLLM" — single endpoint, model aliases, retries, fallbacks, cost tracking — without bundling a Python runtime in the installer. The YAML schema is LiteLLM-compatible so users with an existing `litellm_config.yaml` can drop it in, and so we can swap to an external LiteLLM proxy later (Settings → Advanced → Router URL) with zero config rewrite. Provider adapters: Anthropic, OpenAI, Gemini, AWS Bedrock, Azure OpenAI, Ollama. |
| Default LLMs (configurable) | Claude Sonnet 4.6 (primary, summaries + MOM); GPT-4.1 / Gemini 2.5 Pro as fallbacks | Configurable per-task in Settings. |
| Storage | **SQLite via GRDB.swift**; audio in flat `.wav`/`.flac` per meeting | Local-only, fast queries on transcript text, FTS5 for search. |
| Audio file format | 16-bit PCM WAV at 16 kHz mono for capture/STT; archived as 16 kHz FLAC | Deepgram-friendly sample rate, ~1.5 MB/min compressed. |
| Keychain | macOS Keychain for all STT + LLM API keys, plus the per-install Router master key | No plaintext secrets on disk. Service name pattern: `com.anandthakur.execa.<provider>`. |
| First-run wizard | Guided pane to enter at least one STT key and one LLM key; each "Test connection" button validates with a tiny no-op call | Prevents users hitting opaque errors on the first meeting. |
| Hotkeys | `KeyboardShortcuts` (Sindre Sorhus) | Standard. |
| Packaging | Notarized `.app` via `xcodebuild`, distributed as `.dmg` with **Sparkle** auto-update. Single Universal2 binary, no embedded Python or Docker. Developer ID Application — **not Mac App Store** (sandbox + ScreenCaptureKit constraints make MAS impractical for this class of app). | |

### 3.1 What we deliberately did **not** pick

- **Whisper / pyannote locally** — not chosen for v1 because the user prioritized real-time speaker-labeled transcription. Whisper has no native diarization, and pyannote.audio is offline-only. We keep the door open via the `TranscriptionProvider` protocol and revisit in v2 for "fully offline mode."
- **Electron** — eliminated by user choice; would also need a Swift sidecar or BlackHole for system audio anyway.
- **OpenAI Realtime API for transcription** — does not yet expose diarization on the live stream as cleanly as Deepgram or Sarvam.
- **ElevenLabs Scribe v2 Realtime** — strong overall (93.5 % FLEURS, 150 ms latency) but Hinglish code-switching performance has not been independently demonstrated at the level Sarvam claims; revisit if benchmarks emerge.

### 3.2 STT provider trade-off matrix (Hindi / Hinglish context)

| Aspect | Sarvam Saaras V3 (default) | Deepgram Nova-3 multilingual | Soniox | AssemblyAI Universal-3 Pro |
|---|---|---|---|---|
| Hinglish code-switching mid-sentence | **Architectural primary feature**; trained on 1M+ hrs of code-mixed audio | Supported as one of 10 code-switching languages; ~27 % WER reduction over Nova-2 in Hindi but not Hinglish-first | Marketed as "Hinglish just works"; less public benchmark data | Weak on Indic; English-first model |
| Pure English accuracy (clean) | Good | Excellent | Excellent | Excellent (best DER in noise) |
| Real-time streaming + diarization in one socket | Yes, native | Yes, native | Yes | Yes |
| Time-to-first-token | <150 ms | ~200–300 ms typical | ~200 ms | ~250 ms |
| Indian accent robustness | **Highest** (designed for it) | Decent | Decent | Lower |
| 22 Indic languages support | Yes | Hindi only (others not in code-switch set) | Limited | Limited |
| Vendor maturity / ecosystem | Newer; smaller SDK / community | Mature; large ecosystem | Mid | Mature |
| Data residency in India | Available | US/EU regions | US | US |
| Approx. cost (live, /min) | ~$0.003–0.005 | ~$0.0077 | ~$0.005 | ~$0.0025 |
| Best for | Reliance internal meetings, vendor calls in India, mixed-team standups | Global all-hands, English-only exec meetings, fallback when Sarvam is down | Hinglish secondary option | Pure English meetings where DER matters most |

**Compromises worth being explicit about:**

- *Sarvam advantage, Deepgram cost:* Sarvam wins meaningfully on Hinglish; Deepgram wins on vendor maturity and proven uptime at scale. Defaulting to Sarvam means accepting a younger vendor for a real accuracy gain. Mitigated by automatic fallback to Deepgram on connection failure.
- *Diarization quality on code-switched audio:* Diarizers tied to language-specific acoustic models (Deepgram, AssemblyAI) can over-segment when a speaker switches language because acoustic features shift. Sarvam's diarizer was trained on code-mixed conversations and is more stable across switches. This is the **second** reason — beyond raw WER — to default to Sarvam for this context.
- *No multilingual silver bullet:* Even Sarvam will mis-tokenise rare English jargon spoken in a strongly Hindi accent (product code names, internal acronyms). Mitigation: Sarvam supports a `keywords` / glossary parameter; Deepgram supports `keyterm` prompting on Nova-3 multilingual. The app exposes a per-meeting "Glossary" field that gets passed to whichever provider is active.

### 3.3 Routing strategy

- **Default**: Sarvam Saaras V3 with `language=hi-en` (auto-detect across Hindi + English).
- **Auto-fallback**: if the Sarvam WebSocket fails or returns >5 % timeout/error rate over a 30 s window, the app transparently switches mid-meeting to Deepgram Nova-3 multilingual. A non-blocking banner informs the user.
- **Manual override** in Settings: per-meeting and global default. Choices: `Auto (Hinglish-aware)`, `Sarvam Saaras V3`, `Deepgram Nova-3 multilingual`, `Soniox`, `AssemblyAI`.
- **Per-meeting language profile**: `Hindi+English (Hinglish)` (default for new users in IN), `English only`, `Other` — selects the optimal provider + parameters automatically.

---

## 4. Functional Requirements

### 4.1 Audio capture (Req 1)

- Capture two audio streams concurrently:
  - **System audio**: All output from macOS (or, optionally, only from a chosen app — Zoom, Meet, Chrome, etc.) via `SCStream` configured with `capturesAudio = true` and `excludesCurrentProcessAudio = true`.
  - **Microphone audio**: Default input device via `AVAudioEngine` (or `SCStream.captureMicrophone` on macOS 15+).
- Both are resampled to **16 kHz mono PCM Int16** before being fed to STT.
- The two streams are kept **separate** end-to-end (not pre-mixed) so that:
  - Per-stream diarization quality is preserved — each provider socket sees only one acoustic environment, so the diarizer is not asked to disentangle "in-room voices speaking on top of remote-participant audio playback" inside a single mixed signal.
  - The data model can attribute every transcript token to mic vs. system at insert time via the `(meeting_id, source, raw_speaker_id)` UNIQUE key in `speakers`. No source-recovery heuristics are needed downstream.
- A **mixed master** is also recorded to `meeting_<id>.flac` for archival and re-processing.
- Output device changes (AirPods connect/disconnect) handled via `AVAudioEngine` configuration-change notifications — capture is restarted seamlessly without ending the meeting.
- VAD / silence trim: optional, off by default for v1.
- The two-stream architecture assumes the user is wearing headphones during meetings. When the user uses built-in speakers, system audio bleeds acoustically into the mic stream, producing duplicated audio in `master.flac` and (in Phase 2) duplicated transcription. Acoustic echo cancellation via Voice Processing IO is deferred to a future phase — see `DECISIONS.md`.

#### Permissions required at first launch
- Microphone (`NSMicrophoneUsageDescription`)
- Screen recording / system audio (`NSScreenCaptureDescription`, granted via System Settings → Privacy & Security → Screen Recording)
- Apple Events / Accessibility (only if we add hotkey-driven mute in v2)

### 4.2 Real-time transcription + diarization (Reqs 2 & 3)

- Two persistent WebSocket connections to the active provider (one per stream: mic, system).
- The active provider is selected by the routing logic in §3.3. Both Sarvam and Deepgram adapters conform to a shared `TranscriptionProvider` protocol that emits the same normalized event shape, so the rest of the app is provider-agnostic.

#### Sarvam Saarika (default for Hinglish meetings)
- Endpoint: `wss://api.sarvam.ai/speech-to-text/ws?language-code=<code>&model=saarika:v2.5`
- Auth: `api-subscription-key: <key>` request header on the WebSocket upgrade.
- `language-code` examples: `en-IN`, `hi-IN`, `ta-IN`. (The HinglishGet "auto-detect" wording in earlier drafts was illustrative; Sarvam streaming sets language per-connection.)
- Audio framing on the wire: JSON message per chunk: `{"audio": {"data": "<base64-encoded raw 16-bit PCM>", "encoding": "audio/wav", "sample_rate": 16000}}`. **Not raw binary.**
- **Streaming STT does not support speaker diarization** — diarization is batch-only on the Sarvam API. Both mic and system stream connections collapse all received text into a single speaker ID (0). Speaker labels are assigned via post-hoc batch diarization at meeting-stop; see `DECISIONS.md` 2026-05-08 "Path B" entry.
- Audio format: 16-bit PCM, 16 kHz mono. The `Saaras` family endpoint at `wss://api.sarvam.ai/speech-to-text-translate/ws/{key}` is the *translation* endpoint, not transcription — execa uses Saarika for transcript-fidelity reasons (Devanagari output for Hindi speech, vs. English-translated for Saaras).

#### Deepgram Nova-3 multilingual (English-heavy / fallback)
- Endpoint:
  `wss://api.deepgram.com/v1/listen?model=nova-3&language=multi&diarize=true&punctuate=true&interim_results=true&vad_events=true&endpointing=300&smart_format=true&utterances=true`
- `language=multi` enables Deepgram's 10-language code-switching mode (English + Hindi + 8 others).
- Deepgram supports streaming diarization, unlike Sarvam — when the router picks Deepgram, both streams set `diarize=true` and live transcript carries diarized speaker IDs without needing the post-hoc batch step. This is one reason Deepgram is the failover-of-choice for sessions where live speaker labels matter more than Sarvam's Hinglish accuracy advantage.

#### Common event handling (provider-agnostic)
- Receive events:
  - Interim results with `is_final=false` → rendered in italic/grey in the transcript view.
  - On `is_final=true` (Deepgram) / equivalent finalized event (Sarvam), commit to the transcript store and trigger any pending UI scroll.
- Each normalized transcript token carries: `start_ms`, `end_ms`, `confidence`, `speaker_id` (meaningful only when the active provider supports streaming diarization — Sarvam streaming does not, Deepgram streaming does), `source` (mic / system), `language` (when provider returns it — Sarvam emits per-token language tags for code-switched audio), `meeting_id`.
- Live-streaming speaker map under Sarvam (Phase 2 default; "Path B" — see `DECISIONS.md` 2026-05-08):
  - All mic events → user's `displayName` from settings (fallback `"You"`).
  - All system events → `"Remote"`.
  - `(source, speaker_id)` rows in the `speakers` table during streaming all use `raw_speaker_id = 0`.
- Post-hoc batch diarization (fired at `stopMeeting` if the "Auto-run speaker diarization" setting is on, default on): the saved per-stream WAVs are submitted to Sarvam's batch API with `with_diarization=true`. When batch returns, the rename UI in the meeting detail view (Phase 3+) lets the user assign labels to each batch-derived speaker, optionally seeded from calendar attendees. Live transcript_segments rows are then reassigned to the new speaker IDs.
- Live-streaming speaker map under Deepgram (when routed): standard diarized — `{ source: "mic", speaker_id: 0 }` → `displayName`, additional mic IDs → `"In-room N+1"`, system IDs → `"Speaker N+1"`. Same rename UI applies.
- User can rename any label; the rename updates the display label, the underlying `(source, speaker_id)` tuple is the stable key.
- Auto-reconnect with exponential backoff (up to 5 retries, then surface a banner). On reconnect, audio buffered in a 30 s ring is flushed first.
- Provider failover: if reconnect attempts to Sarvam are exhausted within a 60 s window, the routing layer transparently switches the live meeting to Deepgram. Tokens already committed under Sarvam keep their `provider` tag in the DB; tokens committed after switch are tagged `deepgram`. Speaker IDs are renumbered after switch — the SpeakerLabelManager surfaces a "Map old speakers" prompt so the user can confirm Speaker 1 (Sarvam) = Speaker 1 (Deepgram).

### 4.3 On-demand summaries (Req 4)

- Two summary modes triggered via UI button or hotkey:
  - **Conversation-so-far**: summarizes the entire transcript up to "now."
  - **Per-speaker**: a dropdown lets the user pick a speaker label; the service filters transcript to that speaker only and summarizes their contribution / stance / questions / commitments.
- Summaries are streamed back token-by-token (LiteLLM passes through OpenAI streaming), rendered in a side panel.
- Summaries are stored in SQLite (`summaries` table, see §7) with a timestamp `as_of_ts` so the user can compare snapshots.
- Default models and prompts are in settings; both editable.

#### Default prompt — conversation summary
```
You are summarizing a live business meeting in progress.
Produce a concise summary covering:
- Topics discussed so far (bulleted).
- Decisions made.
- Action items, with owner and due date if mentioned.
- Open questions / unresolved threads.
- Risks or blockers raised.
Be terse. No filler. If something is uncertain, say "unclear".
The transcript is speaker-labeled. Preserve speaker attributions for decisions and action items.
```

#### Default prompt — per-speaker summary
```
You are summarizing what one specific participant ({{speaker}}) said in a meeting.
Produce: their main points, their stated positions, questions they asked, commitments they made, and any concerns they raised. Be terse.
```

### 4.4 Final MOM (Req 5)

- Triggered by "End meeting" or auto on app quit / 30-min idle.
- Uses the **full** transcript (post-finalized, with rename mappings applied).
- System prompt is **fully configurable** in Settings → MOM Template, with placeholders:
  - `{{date}}`, `{{duration}}`, `{{participants}}`, `{{transcript}}`
- Output is stored as Markdown in SQLite and exported to `~/Library/Application Support/com.anandthakur.execa/meetings/<id>/MOM.md`. Optional export to `.docx` via a downstream pandoc call (out of scope for v1; user can add).

#### Default MOM system prompt (editable)
```
You are an executive assistant producing the official Minutes of Meeting (MOM).
Input: a full speaker-labeled transcript of a meeting on {{date}}, duration {{duration}}, with participants {{participants}}.

Produce a Markdown document with the following sections, in order:
1. Title and metadata (date, duration, attendees).
2. Executive summary (3-5 bullets).
3. Discussion notes, grouped by topic, in chronological order. Attribute key statements to speakers.
4. Decisions taken (bulleted; bold the decision).
5. Action items as a Markdown table with columns: Action | Owner | Due Date | Status.
6. Open questions / parking lot.
7. Next steps and proposed follow-up date.

Rules:
- Be precise. Quote verbatim only when a quote is decisive.
- If a field (owner, due date) is not stated, write "TBD".
- Do not invent attendees, decisions, or action items.
- Use Indian English conventions (DD-MM-YYYY dates, INR if currency mentioned).
```

The user can replace this prompt entirely. Multiple named templates supported (e.g. "1:1 review", "Vendor pitch", "Engineering standup").

---

## 5. LLM Routing — `LLMRouter` (in-process, LiteLLM-compatible)

### 5.1 What the router gives us

- **One Swift entry point** for all summary / MOM calls: `LLMRouter.complete(modelAlias:messages:stream:)`. No localhost HTTP, no IPC.
- Per-task model selection via **virtual model aliases** (`summary-fast`, `summary-deep`, `mom-default`) defined in a YAML config the user can edit. The rest of the app never references provider names directly.
- Centralized API keys, read from macOS Keychain at app launch and held in memory only.
- Built-in retries, automatic fallbacks (e.g. Claude → GPT-4.1 on Anthropic 5xx), per-meeting cost tracking, optional caching keyed on `(model, message-hash)`.
- Streaming support (Server-Sent Events shape) so summaries render token-by-token in the UI.

### 5.2 Why a Swift router instead of bundling LiteLLM Python

- **Distribution**: ships as part of the single Swift binary. No PyInstaller bundle (~150–250 MB), no per-dylib code-signing dance, no Python interpreter inside the `.app`, faster startup, simpler notarization.
- **Sandbox**: no child process to spawn — sidesteps the entire class of sandbox-escape concerns and the `master_key` problem (no proxy means nothing for a malicious local app to hijack).
- **Compatibility**: the YAML config is parsed against the LiteLLM schema, so anyone with an existing LiteLLM setup drops their config in and it works. Users who *want* the LiteLLM admin UI / spend dashboard can run `docker compose up -d litellm` themselves and point Settings → Advanced → Router URL at `http://127.0.0.1:4000`. The app then uses HTTP transport instead of in-process calls — same code path, different `LLMTransport` implementation.

### 5.3 Sample LiteLLM-compatible config (shipped as default)

```yaml
model_list:
  - model_name: summary-fast
    litellm_params:
      model: anthropic/claude-haiku-4-5
      api_key: os.environ/ANTHROPIC_API_KEY

  - model_name: summary-deep
    litellm_params:
      model: anthropic/claude-sonnet-4-6
      api_key: os.environ/ANTHROPIC_API_KEY

  - model_name: mom-default
    litellm_params:
      model: anthropic/claude-sonnet-4-6
      api_key: os.environ/ANTHROPIC_API_KEY
    fallbacks:
      - model: openai/gpt-4.1
        api_key: os.environ/OPENAI_API_KEY

router_settings:
  num_retries: 2
  timeout: 60
  fallbacks:
    - mom-default: ["openai/gpt-4.1", "gemini/gemini-2.5-pro"]

litellm_settings:
  drop_params: true

# general_settings.master_key is irrelevant for the in-process router and is
# only read when the user has switched to an external LiteLLM proxy.
```

`api_key: os.environ/ANTHROPIC_API_KEY` is honored: the router resolves `os.environ/<NAME>` against an in-memory env populated from Keychain, **not** the actual process environment. This means no API keys are ever exposed via `ps -E` / `launchctl printenv`.

### 5.4 Settings → Models pane

- Lists virtual model aliases parsed from the active YAML.
- Lets the user pick which alias is used for `summary-fast` vs `summary-deep` vs `mom-default`.
- Friendly form for the common case (provider + model + fallback); "Edit raw YAML" pane for power users.
- "Validate config" button that parses + dry-calls each alias once to surface bad keys / typos.

### 5.5 External-router mode (optional)

For users who want the full LiteLLM admin UI:
- Settings → Advanced → Router URL: e.g. `http://127.0.0.1:4000`.
- Settings → Advanced → Router master key: stored in Keychain, sent as `Authorization: Bearer …`.
- The app's `LLMTransport` switches to HTTP. All other behavior is identical.

---

## 6. Speaker Identification (Req 3 detail)

### 6.1 v1 approach (per user choice)

Diarization is **provider-dependent** and may run live or post-hoc:

- **Sarvam streaming (default in Phase 2)**: streaming STT does *not* support diarization (Sarvam's diarizer is batch-only). Live transcript collapses each stream to a single label — mic → `displayName` (fallback `"You"`), system → `"Remote"`. At `stopMeeting`, if the "Auto-run speaker diarization after meetings" setting is on (default on), execa submits the saved per-stream WAVs to Sarvam's batch API with `with_diarization=true`. When the batch returns, a small rename UI in the meeting detail view (Phase 3+) presents each batch-derived speaker with their first ~10 transcript words and a dropdown — pre-populated from calendar attendees if available, free-text otherwise. The user spends ~15 s assigning labels; the rename retroactively updates the live transcript view and any subsequent summary / MOM call. See `DECISIONS.md` 2026-05-08 "Path B" entry.
- **Deepgram streaming (Phase 6 failover)**: streaming STT supports diarization natively. Live transcript carries diarized speaker IDs in real time; first mic speaker → `displayName`, additional mic speakers → `"In-room 2"`, `"In-room 3"`, etc.; system speakers → `"Speaker 1"`, `"Speaker 2"`, etc. The same rename UI applies, just without the batch step.
- A "Speakers" sidebar (Phase 3) lists all detected speakers across both streams with:
  - Their current label (editable inline).
  - Talk-time so far.
  - A short audio sample (last 3 s) — playback button.
  - "Merge into…" to fix diarizer over-segmentation.
  - "Split…" to mark when one label was actually two people (rare).
- A "Re-run diarization" action in the meeting detail view triggers the batch on demand — useful if the post-hoc run failed silently or if the user wants to regenerate after editing the transcript.
- If a batch result arrives while the user is still in the meeting (long meeting, batch is fast), a non-blocking banner appears: "Speaker labels available — apply?" with **Apply** / **Dismiss**. Dismiss leaves the action available from the meeting detail view (same entry point as the manual re-run).

### 6.2 Data model for forward-compatibility (v2 enrollment)

The `speakers` table stores `(meeting_id, source, raw_speaker_id, display_label, embedding BLOB NULLABLE)`. v2 will populate `embedding` (e.g. via pyannote 3.1 ECAPA-TDNN locally) and add a `known_speakers` table with global embeddings for auto-tagging. **No schema change is required to enable enrollment later.**

---

## 7. Data Model

SQLite, single file at `~/Library/Application Support/com.anandthakur.execa/db.sqlite3`. Schema migrations via GRDB. The bundle-ID-rooted path is required for the sandboxed `.app` to write here without Full Disk Access; `FileManager.default.url(for: .applicationSupportDirectory, …, appropriateFor: nil, create: true)` returns the right container automatically.

```sql
CREATE TABLE meetings (
  id TEXT PRIMARY KEY,            -- ULID
  title TEXT,
  started_at INTEGER NOT NULL,    -- unix ms
  ended_at INTEGER,
  audio_path TEXT,                -- relative path under meetings/<id>/
  status TEXT NOT NULL,           -- 'live' | 'ended' | 'failed'
  notes TEXT
);

CREATE TABLE speakers (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
  source TEXT NOT NULL,           -- 'mic' | 'system'
  raw_speaker_id INTEGER,         -- NULL for mic
  display_label TEXT NOT NULL,
  embedding BLOB,                 -- v2
  UNIQUE(meeting_id, source, raw_speaker_id)
);

CREATE TABLE transcript_segments (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
  speaker_id INTEGER NOT NULL REFERENCES speakers(id) ON DELETE CASCADE,
  start_ms INTEGER NOT NULL,
  end_ms INTEGER NOT NULL,
  text TEXT NOT NULL,
  is_final INTEGER NOT NULL DEFAULT 1,
  confidence REAL
);

CREATE VIRTUAL TABLE transcript_fts USING fts5(
  text, content='transcript_segments', content_rowid='id'
);

CREATE TABLE summaries (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  meeting_id TEXT NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
  kind TEXT NOT NULL,             -- 'conversation' | 'speaker' | 'mom'
  scope_speaker_id INTEGER,       -- non-null when kind='speaker'
  as_of_ts INTEGER NOT NULL,
  model TEXT NOT NULL,            -- LiteLLM alias used
  prompt_template_id INTEGER,
  content_md TEXT NOT NULL
);

CREATE TABLE prompt_templates (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL UNIQUE,
  kind TEXT NOT NULL,             -- 'summary' | 'speaker_summary' | 'mom'
  content TEXT NOT NULL,
  is_default INTEGER NOT NULL DEFAULT 0,
  updated_at INTEGER NOT NULL
);

CREATE TABLE settings (
  key TEXT PRIMARY KEY,
  value TEXT
);
```

Audio files: `~/Library/Application Support/com.anandthakur.execa/meetings/<meeting_id>/master.flac`, optionally `mic.wav` and `system.wav` for re-processing. The `litellm_config.yaml` (user-edited) lives at the same root.

---

## 8. UI / UX

### 8.1 Surfaces

| Surface | Purpose |
|---|---|
| **Menu bar item** | Always present. Shows red dot when recording. Click → start/stop, open meeting, settings. |
| **Floating meeting window** | Live transcript, speaker sidebar, "Summarize now" button, "End meeting & generate MOM" button. Resizable, can be hidden to menu bar. |
| **History window** | Searchable list of past meetings (FTS over transcripts). |
| **Meeting detail view** | Full transcript, summaries timeline, MOM tab, audio scrubber synced to transcript. |
| **Settings window** | Tabs: General, Keys, Audio, Transcription, Models, Prompts, Hotkeys, Privacy, Advanced. |

### 8.2 Live transcript view

- Two-column or speaker-grouped layout (toggleable).
- Each turn: `[mm:ss] **You:** Sure, let's review the Q1 numbers.`
- Interim words shown in light grey; finalized words in normal weight.
- Click a turn → seek the audio (post-meeting).
- "Summarize so far" button (⌘S) on top right.

### 8.3 Hotkeys (defaults, all rebindable)

- ⌘⇧R — start/stop recording
- ⌘S (window-scoped) — summarize so far
- ⌘⇧E — end meeting + generate MOM

### 8.4 States to design for

- No mic permission / no screen recording permission → blocking screen with a "Grant" deep link.
- STT connection lost → top banner, transcript greyed out, audio still buffered locally; router auto-fails over per §3.3.
- All LLM providers unreachable → summaries / MOM disabled with a "Retry" button and the offending error surfaced. Recording and transcription continue. The MOM is generated lazily when the user retries.
- Missing API key for the active model alias → Settings deep-link in the banner.
- Disk full → recording pauses, user notified.

---

## 9. Module / File Layout

```
Execa/
├── App/
│   ├── ExecaApp.swift                # @main, scene config
│   ├── AppCoordinator.swift          # actor coordinating all services
│   └── MenuBarController.swift
├── Audio/
│   ├── AudioCaptureService.swift     # protocol + impl
│   ├── ScreenCaptureKitSource.swift  # system audio
│   ├── MicrophoneSource.swift        # AVAudioEngine
│   ├── AudioMixer.swift              # downmix / archive writer
│   └── AudioRingBuffer.swift
├── Transcription/
│   ├── TranscriptionProvider.swift   # protocol + shared event types
│   ├── SarvamProvider.swift          # default (Hinglish / Indic)
│   ├── DeepgramProvider.swift        # English-heavy / fallback
│   ├── SonioxProvider.swift          # alt
│   ├── AssemblyAIProvider.swift      # alt
│   ├── TranscriptionRouter.swift     # auto-failover, language-profile routing
│   └── TranscriptStore.swift         # in-memory + DB writeback
├── Diarization/
│   └── SpeakerLabelManager.swift     # rename, merge, split
├── LLM/
│   ├── LLMRouter.swift               # alias resolution, retries, fallbacks, cost tracking
│   ├── LLMTransport.swift            # protocol: in-process vs. external-proxy
│   ├── LiteLLMConfig.swift           # YAML parser (LiteLLM-compatible schema)
│   ├── Providers/
│   │   ├── AnthropicProvider.swift
│   │   ├── OpenAIProvider.swift
│   │   ├── GeminiProvider.swift
│   │   ├── BedrockProvider.swift
│   │   ├── AzureOpenAIProvider.swift
│   │   └── OllamaProvider.swift
│   └── PromptTemplate.swift
├── Keys/
│   ├── KeychainStore.swift           # all API keys + router master key
│   └── KeyValidators.swift           # provider-specific test calls
├── Summaries/
│   ├── SummaryService.swift
│   └── MOMService.swift
├── Persistence/
│   ├── Database.swift                # GRDB setup, migrations
│   └── Models/
│       ├── Meeting.swift
│       ├── Speaker.swift
│       ├── TranscriptSegment.swift
│       └── Summary.swift
├── UI/
│   ├── LiveMeetingView.swift
│   ├── SpeakerSidebar.swift
│   ├── MeetingHistoryView.swift
│   ├── SetupWizardView.swift          # first-run keys + provider check
│   ├── SettingsView/
│   │   ├── KeysPane.swift
│   │   ├── ModelsPane.swift
│   │   ├── PromptsPane.swift
│   │   ├── AdvancedPane.swift         # external router URL, raw YAML
│   │   └── ...
│   └── Components/
├── Telemetry/
│   └── CrashReporter.swift            # opt-in, scrubbed, off by default
├── Resources/
│   └── default-litellm-config.yaml    # shipped default; copied to user dir on first run
└── Tests/
    ├── AudioCaptureTests.swift
    ├── SarvamProviderTests.swift
    ├── DeepgramProviderTests.swift
    ├── LLMRouterTests.swift
    └── ...
```

---

## 10. Non-Functional Requirements

- **Latency**: end-of-utterance to displayed final word < 1.2 s p95 on broadband.
- **CPU**: idle < 5%, while recording < 25% on M-series.
- **Memory**: < 400 MB resident during a 2-hour meeting.
- **Disk**: ~1.5 MB / minute archived audio, ~5 KB / minute transcript.
- **Cost guardrails (visible in Settings)**:
  - Sarvam Saaras V3 streaming ≈ $0.003–0.005 / min (live) → ~$0.18–0.30/hr.
  - Deepgram Nova-3 streaming ≈ $0.0077 / min (live) → ~$0.46/hr.
  - Soniox / AssemblyAI: ~$0.005 and ~$0.0025 / min respectively.
  - Claude Sonnet 4.6 summary on a 1-hour meeting ≈ ~$0.05–0.15 depending on prompt.
  - LiteLLM tracks per-meeting LLM spend; the Transcription layer tracks STT spend per provider; both surfaced in History view.
- **Offline behavior**: recording continues, transcripts queue, are flushed when connectivity returns. Summaries and MOM gated until LLM reachable.
- **Crash safety**: WAL-mode SQLite, audio flushed every 1 s; on relaunch, half-finished meetings are recoverable.

---

## 11. Security & Privacy

### 11.1 Keys & secrets

- API keys live in macOS Keychain only, accessed via the Security framework. Service name: `com.anandthakur.execa.<provider>` (e.g. `…sarvam`, `…deepgram`, `…anthropic`).
- Keys are loaded into in-memory env on app launch and on Settings change. They are **never** written to disk, never put in the process environment (`ps -E` is clean), and never logged.
- The default `litellm_config.yaml` references keys via `os.environ/<NAME>` — resolved by `LLMRouter` against the in-memory env, not the OS env.
- If the user enables external-router mode, the LiteLLM master key is also Keychain-stored and sent only over `127.0.0.1`.

### 11.2 Network

- Outbound traffic only to: the active STT provider's WebSocket endpoint (Sarvam, Deepgram, Soniox, or AssemblyAI per user config) and the configured LLM provider HTTPS endpoints. In external-router mode, additionally `127.0.0.1:<port>` for the user's own LiteLLM proxy.
- Sarvam offers India data residency; if the user enables "Keep audio in India" in Privacy settings, the routing layer will refuse to fall back to non-Indian endpoints and instead pause transcription, surfacing a banner.

### 11.3 Sandbox & file paths

- App is sandboxed (`com.apple.security.app-sandbox`) with entitlements:
  - `com.apple.security.device.audio-input` — microphone.
  - `com.apple.security.device.camera` — *not* set.
  - `com.apple.security.network.client` — outgoing network.
  - Screen Recording permission — granted by user via System Settings, not an entitlement.
  - `com.apple.security.files.user-selected.read-write` — for the export-to-folder action.
  - Hardened Runtime enabled. No `allow-jit`, no `allow-unsigned-executable-memory`, no `disable-library-validation`.
- All persistent files live under the sandbox container at `~/Library/Application Support/com.anandthakur.execa/` and `~/Library/Caches/com.anandthakur.execa/`. No paths outside the container are written to.

### 11.4 User-facing privacy controls

- "Privacy mode" toggle: pause transcript streaming (audio still recorded locally); when resumed, the buffered audio is sent to STT (or discarded, user's choice).
- Per-meeting "Delete recording" wipes audio + DB rows + summaries (single transaction, hard delete).
- "Erase all data" in Settings → Privacy: deletes everything under the sandbox container and resets the app to first-run state.

### 11.5 Crash reporting (opt-in)

- Default: **off**. No data leaves the machine.
- Settings → Privacy → "Send anonymous crash reports" toggle.
- When on: stack traces only — never transcript text, never audio paths, never API keys, never participant names. A scrubber strips any string that matches a Keychain-stored key prefix or a `~/Library/Application Support/...` path before submission.
- Implementation: Apple's `MetricKit` for diagnostics + Sentry SDK with `beforeSend` scrubber. No third-party analytics.
- The toggle is also presented in the first-run wizard with the default off; the user must explicitly opt in.

### 11.6 No analytics

- No usage telemetry, page-view tracking, or A/B experimentation. Ever. This is a non-negotiable stance for an executive-meeting tool.

---

## 12. Configuration (Settings)

| Pane | Setting | Default |
|---|---|---|
| General | Display name (used as "You") | from `NSFullUserName()` |
| General | Open at login | off |
| Keys | Sarvam API key | empty (validated) |
| Keys | Deepgram API key | empty (validated) |
| Keys | Soniox API key | empty |
| Keys | AssemblyAI API key | empty |
| Keys | Anthropic API key | empty (validated) |
| Keys | OpenAI API key | empty |
| Keys | Gemini API key | empty |
| Keys | AWS Bedrock access key + secret + region | empty |
| Keys | Azure OpenAI key + endpoint | empty |
| Keys | Ollama URL (local) | empty |
| Audio | Input device | system default |
| Audio | Capture target | "All system audio" or per-app picker |
| Audio | Archive format | FLAC |
| Transcription | Provider | `Auto (Hinglish-aware)` — Sarvam primary, Deepgram fallback |
| Transcription | Language profile | `Hindi + English (Hinglish)` |
| Transcription | Per-meeting glossary (acronyms, names) | empty |
| Transcription | Diarize system audio | on |
| Transcription | Auto-failover provider | Deepgram Nova-3 multilingual |
| Models | Summary model alias | `summary-deep` |
| Models | MOM model alias | `mom-default` |
| Models | Edit raw `litellm_config.yaml` | — |
| Prompts | Conversation summary template | (default above) |
| Prompts | Per-speaker summary template | (default above) |
| Prompts | MOM template (multiple, named) | "Default", "1:1", "Vendor pitch", … |
| Hotkeys | All bindings | as in §8.3 |
| Privacy | Auto-delete after N days | off |
| Privacy | Keep audio in India (Sarvam-only) | off |
| Privacy | Send anonymous crash reports | **off** (opt-in) |
| Advanced | Use external LLM router | off (in-process) |
| Advanced | External router URL | `http://127.0.0.1:4000` |
| Advanced | Router master key | empty (Keychain) |

All settings are persisted to the `settings` table; prompts to `prompt_templates`.

---

## 13. Build, Packaging & Distribution

### 13.1 Build

- Xcode 16+, Swift 5.10, deployment target macOS 14.0, Universal2 (Apple Silicon + Intel).
- Dependencies via Swift Package Manager only — no Homebrew, no Python, no Node:
  - `GRDB.swift` — SQLite.
  - Native `URLSessionWebSocketTask` for STT WebSockets (no Starscream needed in current Swift versions).
  - `KeyboardShortcuts` (Sindre Sorhus).
  - `Yams` — YAML parser for the LiteLLM-compatible config.
  - `Sparkle` — auto-update.
  - `Sentry-Swift` — opt-in crash reporting only.

### 13.2 Distribution

- **Direct distribution via Developer ID Application + DMG**, *not* Mac App Store. MAS would block ScreenCaptureKit with system-audio capture and force sandbox restrictions that don't match this app's needs. This is a deliberate choice consistent with peer products (Granola, Loom, Rewind).
- Code-signing: Developer ID Application certificate.
- Hardened Runtime: enabled. No exception entitlements.
- Notarization: via `notarytool` in CI; staple with `xcrun stapler`.
- DMG built with `create-dmg`; signed.
- Auto-update: Sparkle 2 with EdDSA-signed update feed hosted on a static origin (S3/CloudFront). Delta updates enabled.
- Single-binary install footprint: ~25 MB (Swift app + assets). No Python, no Docker, no embedded webview.

### 13.3 First-run experience

1. macOS Gatekeeper check passes (notarized).
2. App opens to the **Setup Wizard** (`SetupWizardView`):
   - Step 1: Permissions — request Microphone and Screen Recording. Each has a "Why we need this" explanation and a "Open System Settings" deep-link.
   - Step 2: STT key — paste Sarvam (recommended) and/or Deepgram. "Test" button hits a no-op endpoint.
   - Step 3: LLM key — paste at least one (Anthropic recommended). "Test" button does a 1-token completion.
   - Step 4: Optional — display name, language profile, Sparkle auto-update preference, opt-in crash reporting.
3. On finish, the default `litellm_config.yaml` is copied to `~/Library/Application Support/com.anandthakur.execa/litellm_config.yaml` and the app lands on an empty Meeting History view with a prominent "Start meeting" button.

### 13.4 CI

- GitHub Actions on `macos-15` runners:
  - `swift build` + `xcodebuild test` for unit tests.
  - Mock-server integration tests (Sarvam/Deepgram WS fixtures, fake LLM transport).
  - Notarization gate runs only on tagged releases; uses Apple credentials in repo secrets.
- Artifacts: signed `.app`, `.dmg`, Sparkle appcast XML.

---

## 14. Testing

- **Unit tests**: audio resampling correctness, JSON parsing for each STT provider, LiteLLM YAML parsing edge cases, prompt template substitution, DB migrations, Keychain wrapper round-trip.
- **Integration tests**:
  - Mock STT WebSocket servers for Sarvam and Deepgram, replaying captured fixtures (one ground-truth 5-min Zoom call with 3 speakers in Hinglish, one in pure English, stored in `Tests/Fixtures/`).
  - `LLMRouter` driven by a `MockLLMTransport` that returns scripted responses; verifies retries, fallback chains, and cost tracking math.
  - End-to-end: feed an audio fixture in, assert MOM markdown matches a golden snapshot (within tolerance for LLM nondeterminism — tested by structural shape, not exact text).
- **Manual QA matrix**:
  - macOS 14, 15, 16; M2 / M4 / Intel.
  - Headphones (AirPods), built-in mic, USB mic.
  - Zoom, Meet, Teams, Slack Huddle, FaceTime.
  - Hot-swap output device mid-meeting.
  - Lose network mid-meeting.
- **Latency probe**: synthetic test that injects a known TTS clip and measures word-final latency.

---

## 15. Out of Scope (v1) / Roadmap

| v1.x | v2 |
|---|---|
| Auto-update via Sparkle | Persistent voice enrollment + auto-tagging across meetings (pyannote) |
| `.docx` MOM export via pandoc | Calendar integration (auto-detect meetings from EventKit) |
| MOM export to Notion / Confluence | Fully offline mode (Whisper + pyannote + local Ollama via LiteLLM) |
| Per-meeting tags + folders | Search across all meetings (already FTS-ready) UI |
| | Translation of transcripts |
| | Slack / Email send of MOM |

---

## 16. Open Questions / Decisions Deferred to Implementation

1. **macOS minimum** — proposed 14.0, but if mic-via-ScreenCaptureKit is preferred over AVAudioEngine, raise to 15.0. Recommend keeping 14.0 to widen install base; AVAudioEngine path is fine.
2. **Default LLM** — Claude Sonnet 4.6 for both summary and MOM; revisit after first usage data. For Hinglish meetings the LLM step itself is robust; Sonnet handles Devanagari and code-mixed text well, so no LLM-side change is required.
3. **Default STT provider** — Sarvam Saaras V3 for the Indian context; can be flipped to Deepgram in Settings → Transcription. Re-evaluate after one month of real meetings: if Sarvam's diarization or uptime under-performs in practice, switch the default to Deepgram Nova-3 multilingual without any code change.
4. **MOM language** — by default the MOM is generated in the same dominant language as the meeting; for Hinglish meetings the default prompt produces an English MOM (most useful for executive readers). A toggle in Prompts pane lets the user switch to "Match meeting language" or "Hindi (Devanagari)" or "Both side-by-side."
5. **Speaker diarization on the mic stream** — currently disabled (mic = local user). If multiple people share one mic (in-room meetings), expose a setting "Diarize my mic too."
6. **Audio retention** — keep raw audio forever (until user deletes), or auto-delete after MOM is generated? Recommend keep until user deletes; adjustable in Privacy.
7. **Glossary scope** — per-meeting glossary is in v1; a global glossary (organization acronyms, brand names like Ajio / Tira / Netmeds) would help across meetings. Defer to v1.1 once we see what terms the diarizer/STT consistently mistokenises.
8. **Provider adapter coverage in `LLMRouter`** — v1 ships Anthropic, OpenAI, Gemini, Bedrock, Azure OpenAI, Ollama. Cohere, Mistral, Groq, Together, Fireworks deferred to v1.1 unless a real user need surfaces. Users on those providers can switch to external-router mode and run their own LiteLLM proxy.
9. **Code-signing identity** — needs an Apple Developer Program enrollment under the Reliance entity (Team ID TBD) before any signed build can be distributed externally. Track separately.

---

## 17. Acceptance Criteria for v1

- [ ] Start a meeting from the menu bar; capture mic + system audio; live transcript appears within 2 s of first speech.
- [ ] System-audio speakers are tagged as `Speaker 1/2/...`; rename persists for the meeting and is reflected in summaries and MOM.
- [ ] "Summarize so far" produces a coherent summary of the conversation up to that moment, with attributions.
- [ ] "Summarize speaker X" produces a contribution-focused summary for one speaker.
- [ ] On meeting end, MOM.md is written to disk using the configured (editable) system prompt.
- [ ] Settings → Models lets the user pick a different LLM alias and have it take effect on the next call without restart.
- [ ] First-run wizard collects keys, validates them, and refuses to proceed without one STT and one LLM key.
- [ ] No data is sent anywhere except to the user's configured STT provider (Sarvam / Deepgram / etc.) and the configured LLM provider through `LLMRouter`. Verified by network capture (Little Snitch / Charles).
- [ ] All audio, transcripts, summaries, and MOMs remain on the local machine, under the sandbox container at `~/Library/Application Support/com.anandthakur.execa/`.
- [ ] Notarized DMG installs cleanly on a fresh macOS 14 machine with no developer tools, and a meeting completes end-to-end including MOM generation.
- [ ] Crash reporting is off by default and only enabled by explicit user opt-in.

---

*End of spec.*
