# CLAUDE.md

Orientation for Claude Code working on **execa**. The full specification is in `meeting-app-spec.md` — read it before any non-trivial change. Phasing and current progress are tracked in `BUILD_PLAN.md`. Architectural decisions already locked in are listed in `DECISIONS.md`; do not re-open those without a new entry.

## Product name vs. Xcode name (load-bearing)

These differ on purpose; do not "normalize" them.

- **`execa`** (lowercase) — user-visible product name (`CFBundleDisplayName`, dock, menu bar).
- **`Execa`** (PascalCase) — Xcode project, Swift module, app bundle target, test target (`ExecaTests`).
- **`com.anandthakur.execa`** — bundle identifier and Keychain service prefix (e.g. `com.anandthakur.execa.sarvam`, `…anthropic`).

## Non-negotiables

Refuse changes that violate any of these. If a task seems to require it, raise the conflict instead of working around it.

- **Single signed Swift app.** No child processes, no Python runtime, no Docker, no embedded webview. The `LLMRouter` is in-process Swift — see spec §5.
- **Mic and system audio streams stay separate end-to-end.** Never pre-mix upstream of the diarizer — the "You" label and diarization quality depend on this. Spec §4.1.
- **Sandbox + Hardened Runtime always on.** No `allow-jit`, no `disable-library-validation`. All persistent files under `~/Library/Application Support/com.anandthakur.execa/` and `~/Library/Caches/com.anandthakur.execa/`. Spec §11.3.
- **API keys: macOS Keychain only.** Loaded into in-memory env at launch; never written to disk, never placed in the process environment (`ps -E` must stay clean), never logged. `os.environ/<NAME>` references in the YAML config resolve against this in-memory env, **not** the OS env. Spec §11.1.
- **No analytics, ever.** Crash reporting (MetricKit + Sentry) is opt-in, default off, scrubbed for paths and Keychain key prefixes before submission. Spec §11.5.
- **Developer ID + DMG + Sparkle.** Not Mac App Store. Do not introduce dependencies or entitlements that assume MAS. Spec §13.2.
- **No direct provider names in app code.** Summary and MOM call sites go through `LLMRouter` aliases (`summary-fast`, `summary-deep`, `mom-default`). STT call sites go through the `TranscriptionProvider` protocol.

## Dependencies — SPM only

Sanctioned: `GRDB.swift`, `KeyboardShortcuts` (Sindre Sorhus), `Yams`, `Sparkle`, `sentry-cocoa` (product `Sentry`). WebSockets via native `URLSessionWebSocketTask` — no Starscream. No Homebrew runtime deps, no Python, no Node. Adding anything outside this list needs an explicit reason tied to a spec requirement, recorded in `DECISIONS.md`.

## Code conventions

- Swift 5.10, deployment target macOS 14.0.
- SwiftUI-first; AppKit only where SwiftUI is insufficient (status item, permission prompts).
- Concurrency: async/await and actors. Avoid Combine for new code.
- No force-unwraps in production code. `try!` only in test fixtures.
- One type per file unless trivially small (<20 lines) and tightly coupled.
- SwiftLint and SwiftFormat configs at repo root; both must pass clean.
- Tests: Swift Testing (`@Test`, `#expect`) for unit and integration tests. XCTest only inside a UI-test target if one is ever added (XCUI is XCTest-only).

## Definition of done

For every change before declaring it complete:

1. `xcodebuild -scheme Execa build` clean.
2. `xcodebuild -scheme Execa test` passes.
3. `swiftlint` zero warnings.
4. `swiftformat --lint .` clean.
5. New service code has unit tests; anything touching network or filesystem has at least one integration test against a mock.
6. No new entries in `Resources/` other than the default LiteLLM YAML and bundled assets.

## Spec navigation

Jump straight to these sections rather than re-deriving:

- §2 architecture, §2.1 process model
- §3 technology choices, §3.1 deliberate non-choices, §3.2 STT trade-offs, §3.3 routing
- §4 functional requirements (audio, transcription, summaries, MOM)
- §5 `LLMRouter` (including external-router mode)
- §6 speaker labeling and v2 enrollment forward-compat
- §7 SQLite schema
- §9 file layout
- §11 security and privacy
- §13 build, packaging, distribution
- §17 acceptance criteria

## Commands

Post-scaffold (Phase 0):

- Build: `xcodebuild -scheme Execa -configuration Debug build`
- All tests: `xcodebuild -scheme Execa test`
- Single test: `xcodebuild -scheme Execa test -only-testing:ExecaTests/<TestClass>/<testMethod>`
- Format: `swiftformat .`
- Lint: `swiftlint`
- Release: `xcodebuild archive` → `xcrun notarytool submit` → `xcrun stapler staple` → `create-dmg`. CI runs on `macos-15` GitHub runners; notarization is gated to tagged releases.
