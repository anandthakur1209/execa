# BUILD_PLAN.md

Phased delivery plan for **execa**. Each phase ends in a runnable, demoable build with explicit acceptance criteria. Do not merge across phase boundaries until the prior phase's criteria pass.

The full specification is in `meeting-app-spec.md`; locked-in architectural decisions are in `DECISIONS.md`. This file tracks *what we're doing now* and *what comes next*.

---

## Current status

**Phase 3.5b complete (tagged `phase-3.5b`). Ready for Phase 4.** Phase 3.5 manual smoke surfaced an algorithmic weakness: Jaccard similarity over raw tokens fails on the most common bleed pattern (mic captures a fragment of a longer system segment — containment is high but Jaccard is low). Phase 3.5b ships a v2 algorithm under a new `bleed_dedup_algorithm_version` settings key (default `"v2"`, v1 retained as flag-fallback): containment coefficient (`|mic ∩ system| / |mic|`) ≥ 0.75 over Porter-light-stemmed tokens; ASCII-only stemmer (Devanagari pass-through); concatenation pre-pass that scores consecutive same-speaker mic fragments inside one containing system segment as one unit; cross-validation post-pass that promotes the remaining unflagged segments of any mic speaker who's already ≥ 80% flagged with ≥ 3 absolute flagged segments. The Phase 3.5 design (soft-delete via `transcript_segments.deduped_against_segment_id`, view-layer orphan-speaker filter via `SpeakerQueries.visibleSpeakers`, two-write swap-then-dedup pattern) is unchanged — v2 swaps only the scoring function and adds two passes.

**Phase 3.5 (foundation, still Active):** Post-batch speaker-bleed dedup pass — when the user runs a meeting on built-in speakers (no headphones), the laptop's speakers play remote audio into the room and the mic re-captures it; the same remote voice gets transcribed both as a system-side `Speaker N` AND a mic-side `In-room N+1`. Dedup pass identifies mic-side segments mirroring system-side segments in time AND text and soft-deletes them via the `transcript_segments.deduped_against_segment_id` column (v4 migration). v1's Jaccard 0.6 scoring is now superseded by v2's containment 0.75 (above); the soft-delete + view-filter design carries forward unchanged. Direction is one-way (mic flagged as bleed of system). Settings: `auto_speaker_bleed_dedup` (default `true`) gates the pass; `bleed_dedup_algorithm_version` (default `"v2"`) picks the algorithm. Two-write design (swap then dedup in separate writes) is intentional — testability + maintainability over an atomic transaction.

Phase 3's foundation: post-meeting Sarvam batch diarization pipeline runs automatically at `stopMeeting` (gated by the `auto_diarization` setting, default-on), submitting `mic.wav` and `system.wav` as two parallel jobs to the Sarvam batch v1 endpoint with authoritative-replace swap into the DB; `SpeakerSidebar` (live) + `MeetingDetailView` (post-meeting) host rename / cross-source merge / right-click split; voice-sample playback walks the merge alias per Revision 5; "Open last meeting" menu-bar item reaches the detail window without a TTL.

Phase 2's known issue (Resume after bad-key replacement requires app relaunch) carries forward.

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

**Known consequence (carried over from Phase 1 closeout):**
- In speaker-mode (no headphones), mic-stream STT will transcribe remote-participant audio bleeding through speakers and tag it as "You". The same audio also arrives via system-stream STT correctly tagged with diarization. Result: doubled transcript entries in speaker mode. Mitigation deferred (see `DECISIONS.md` 2026-05-07 Phase 1 closeout).

**Known issue — Resume after bad-key replacement requires app relaunch:**
- Repro: start a meeting with a bogus Sarvam key → reconnect attempts exhaust → "Transcription stopped" banner with Resume button. While the meeting is still live, replace the Keychain key with a valid one (`security add-generic-password -s com.anandthakur.execa.sarvam -a default -w '<real>' -U`). Click Resume.
- Expected: transcription resumes mid-meeting.
- Actual: pill briefly shows "Connected" but transcripts don't appear; subsequent meetings in the same process also fail. Workaround: quit and relaunch — the next meeting transcribes normally.
- Suspected root cause: stale `URLSession` or `URLSessionWebSocketTask` state cached after the bogus-key auth failures, surviving the per-provider tear-down. Each relaunch instantiates a fresh `URLSession` and the issue clears. Distinct from the BUG 5 in-process Resume (network-drop → reconnect-exhaust → resume), which the `retry()` path covers.
- Acceptable for v1: the bogus-key path is an explicit user error and the workaround is fast (Quit → Start). Revisit in Phase 6 when `TranscriptionRouter` introduces failover and the URLSession ownership model gets a fresh look. Tracked in DECISIONS.md if it surfaces as a real workflow blocker.

**Acceptance:**
- Live transcript displays within 2 s of first speech.
- Network drop mid-meeting → banner appears, audio buffered, transcript catches up on reconnect.
- Back-to-back meetings in the same process both transcribe (the BUG 6 gate). Covered by `BackToBackMeetingTests.backToBackMeetingsBothTranscribe` and a manual smoke step.

---

## Phase 3 — Diarization labels and speaker management

**Goal:** Anonymous Speaker IDs become rename-able. Merge / split for diarizer errors. Sarvam batch diarization client + auto-trigger at `stopMeeting` + result reconciliation + speaker management UI (rename / merge / split) on top.

**Scope:**
- `Diarization/SarvamBatchClient.swift` — batch STT upload with `with_diarization=true`.
- `Diarization/DiarizationService.swift` — auto-trigger at `stopMeeting`, parallel per-stream batch calls, swap-in-DB transaction, status published via `DiarizationStatusStore`.
- `Diarization/SpeakerLabelManager.swift` — rename, merge (cross-source), split; updates apply retroactively to past turns via the `display_label` join (no segment-row updates).
- `UI/SpeakerSidebar.swift` — list of speakers with live talk-time and 3-second voice-sample playback (post-meeting only). Sidebar single-click rename is the canonical surface.
- `UI/MeetingDetailView.swift` — minimal post-meeting host: speaker list, transcript with single-turn split, "Re-run diarization" button (with confirmation), single-button "Got it" announcement when batch lands. Phase 5 expands for History.
- "You" auto-labeling on the mic stream — already wired in Phase 2 via `TranscriptStore.defaultLabel`; preserved across batch swap for `(mic, raw_speaker_id=0)` rename per DECISIONS.md (Phase 3 mic-rename-preservation entry).
- DB writes go through the `speakers` table; the `(meeting_id, source, raw_speaker_id)` tuple is the stable key. v3 migration adds `merged_into_speaker_id` (cross-source-capable alias FK) and three `meetings.diarization_*` columns.

**Acceptance:**
- Rename a speaker mid-meeting → all past and future turns reflect the rename.
- Merge two speakers (including cross-source) → both clusters point to the same effective `display_label`; talk-time aggregates correctly.
- Split → introduces a new `speakers` row and reassigns selected segments.
- Back-to-back meetings each diarize independently (the "do it twice" gate from Phase 2's lessons-learned).

---

## Phase 3.5 — Speaker bleed-through dedup

**Goal:** When the user runs a meeting on built-in speakers (no headphones), the laptop's speakers play remote audio into the room and the mic re-captures it; the same remote voice gets transcribed both as a system-side `Speaker N` AND a mic-side `In-room N+1`. Phase 3.5 ships a deterministic post-batch dedup pass that recognises the mirror pattern and soft-deletes the mic-side rows. The thorough fix (acoustic echo cancellation via Voice Processing IO) is parked per the Phase 1 closeout decision; this phase is the deterministic alternative.

**Scope:**
- v4 migration: `transcript_segments.deduped_against_segment_id INTEGER REFERENCES transcript_segments(id) ON DELETE SET NULL`. Soft-delete + audit on the same column.
- `Diarization/SpeakerBleedDeduper.swift` — pure-function namespace running inside a caller-provided GRDB write block. Algorithm: for each mic-side segment M, find any system-side segment S with ≥50% time overlap (relative to the shorter side) AND ≥0.6 jaccard text similarity (lowercased + unicode-tokenized); flag M as bleed-of-S. Skip pairs where either side is < 1 s or has confidence < 0.6. NULL confidence proceeds.
- `Persistence/SpeakerQueries.swift` — new helper `visibleSpeakers(meetingID:in:)` filtering out `speakers` rows whose every segment has `deduped_against_segment_id IS NOT NULL`. `talkTimeAggregated` adds the same filter. Single source of truth for the orphan-speaker `EXISTS` predicate.
- `Diarization/DiarizationService.runForMeeting` — gates dedup on `auto_speaker_bleed_dedup` setting (default `true`); runs in a follow-up `database.queue.write` after swap (NOT same transaction — testability + maintainability trade-off documented inline). Re-run diarization re-applies the dedup; never preserves previous dedup decisions.
- UI filters: `SpeakerSidebar.derive` and `MeetingDetailView` queries call `visibleSpeakers` for orphan-speaker filtering and add `WHERE t.deduped_against_segment_id IS NULL` to transcript-row queries.
- Settings: `auto_speaker_bleed_dedup` key on `settings` table, default `true`. Reachable only via direct DB edit until Phase 5's Settings UI.
- Direction is one-way: mic-side flagged as bleed of system-side; never the reverse. The user's voice loop-back via system audio is rare and bidirectional dedup risks losing legitimate mic-side speech.

**Acceptance:**
- Speaker-mode meeting playing single-voice content through laptop speakers → post-diarization, only system-side `Speaker N` rows appear in the sidebar; mic-side rows exist in DB but are filtered. `transcript_segments.deduped_against_segment_id` populated on the soft-deleted mic-side rows pointing at the surviving system-side IDs.
- Paraphrase guard: mic-side user paraphrases a system-side remote speaker's sentence → both turns are visible (text similarity below threshold).
- `auto_speaker_bleed_dedup=false` → dedup pass skipped entirely; both mic and system rows visible (Phase 3 behavior).
- Re-run diarization re-applies dedup against the freshly-swapped state.
- Back-to-back meetings each dedup independently per `meeting_id` (the "do it twice" gate from Phase 2's lessons-learned).
- Phase-3-era meetings on disk render unchanged after v4 migration (column is NULL → filter is a no-op).

---

## Phase 3.5b — Bleed dedup algorithm v2

**Goal:** Phase 3.5's Jaccard-based dedup fails on the most common bleed pattern: when the mic captures a fragment of a longer system segment, the |intersection| / |union| ratio falls below threshold and dedup correctly skips per the rule but leaves visible duplicates. Phase 3.5b replaces Jaccard with containment, adds token stemming, and adds two structural passes (concatenation pre-pass + cross-validation post-pass) to catch fragment patterns and whole-speaker bleed.

**Scope:**
- `bleed_dedup_algorithm_version` settings key, default `"v2"`; v1 retained as flag-fallback for A/B regression.
- v2 pairwise core: same eligibility + time-overlap gate as v1, but uses containment ≥ 0.75 over Porter-light-stemmed tokens.
- Porter-light stemmer: six rules (ies→y, ied→y, ing→, ed→, es→, s→) with min-input-length guards; ASCII-only (Devanagari and other non-ASCII tokens pass through untouched).
- Concatenation pre-pass: groups consecutive same-speaker mic segments that fall entirely within one system segment's time window; joins their text and scores the joined string as one unit. Catches "mic captured several short fragments of one long system utterance."
- Cross-validation post-pass: when ≥ 80% of a mic speaker's segments are flagged AND ≥ 3 in absolute count, promote the remaining unflagged segments to flagged. Audit FK on promoted rows points at the nearest-neighbor system segment by `startMs` within the most-frequent target system speaker. Catches "whole mic speaker is just bleed echo."
- `DedupPair` audit struct gains `containment`, `jaccard`, and `promotionReason` (`.pairwise` / `.concatenation` / `.speakerPromotion`) for in-memory debugging; only the FK is persisted.
- v2 code lives in `SpeakerBleedDedupV2.swift` as an extension on `SpeakerBleedDeduper`; v1 path in `SpeakerBleedDeduper.swift` is fully unchanged.

**Acceptance:**
- Regression test: 30-token mic ⊂ 90-token system at 90% overlap. v1 does NOT flag (jaccard 0.33); v2 DOES flag (containment 1.0). Both pinned forever.
- Paraphrase guard survives v2: legitimately different word choice at high overlap stays not-flagged.
- Concat pre-pass flags multi-fragment mic capture inside one system segment; alternating speakers + sub-1 s totals + low-confidence groups + multi-system spans correctly skipped.
- Cross-validation promotes 4-of-5 mic-speaker pattern; 2-of-5 / 3-of-4 / 2-segment-with-2-flagged correctly NOT promoted; nearest-neighbor audit FK and lowest-id tie-break deterministic.
- v1 flag-fallback: `UPDATE settings SET value='v1' ...` + Re-run reverts to Phase 3.5 behavior.
- Phase-3.5-era meetings on disk render correctly under v2 default (existing audit FKs respected; new dedup runs apply v2 on Re-run).

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
- Per-source first-frame timestamp alignment in `AudioMixer.writeMasterFLAC` (cross-references the `// FIXME(phase-5)` in `Audio/AudioMixer.swift`). Phase 1 aligns from frame 0 of each source so any startup-latency difference between mic and system shows up as up to ~100 ms of lip-sync drift in `master.flac`. Fix: consult `PCMChunk.captureTime` and pad the lagging source's head with silence to align before mixing.

**Acceptance:**
- "End meeting" produces a non-empty MOM.md matching the configured template's structural shape.
- History search returns hits across past meetings.
- `master.flac` mix-down has no audible lip-sync drift between mic and system audio in History playback.

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
- **"Do it twice" smoke rule.** Every phase's manual smoke checklist must include a back-to-back run of the phase's primary user-facing flow (`Start meeting → use → stop → Start meeting again → use → stop`). Phase 2 shipped with a one-meeting-only smoke and three subsequent rounds of manual testing surfaced a "second meeting in same process doesn't transcribe" deadlock that no amount of one-shot testing would have caught — the bug was in lifecycle state shared across meetings, not in any single meeting's behaviour. Lifecycle state-leak bugs are a recurring failure mode for actor-owned `AsyncStream`s; the only reliable defence is exercising start → stop → start in both automated tests and manual smokes.
