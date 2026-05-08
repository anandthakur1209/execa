# Test fixtures

Resources used by the test target only. **Never shipped in the production
app bundle** — `Bundle(for: type(of: self))` resolves these at test runtime
because the file is part of the test target's compiled resources, not the
app target's.

## Files

### `hello.wav`
- 16 kHz Int16 mono PCM, ~3 s of "hello, this is a phase 2 transcription test"
  spoken by macOS `say`.
- Used by `SarvamProviderIntegrationTests` to drive a real Sarvam streaming
  WebSocket without recording live audio. Regenerate with:
  ```sh
  say -o /tmp/hello.aiff "hello, this is a phase 2 transcription test"
  afconvert /tmp/hello.aiff -d LEI16@16000 -c 1 -f WAVE Execa/ExecaTests/Fixtures/hello.wav
  ```

### `sarvam-data-sample.json`
- Sample server message in the shape observed in
  [sarvamai/sarvam-streaming-apis](https://github.com/sarvamai/sarvam-streaming-apis)
  HTML script (`html-scripts/stt.html`).
- Drives `TranscriptionProviderProtocolTests`'s decoder gate.
- Captured statically from the published sample, **not** from a live
  probe. Commit 5's live probe will replace this fixture with real wire
  output and may add interim/error variants if Sarvam streaming actually
  emits them.
