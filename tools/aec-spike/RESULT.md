# A0 AEC spike — RESULT (2026-07-03)

**Verdict: 🟢 GO — via a SEPARATE-engine design. The shared-engine design is a NO-GO on this macOS.**

Machine: MacBook Air, macOS Darwin 25, built-in mic (1ch) + speakers (2ch).
Harness: this directory (`main.swift` → `AECSpike.app`), built with plain `swiftc`.
It never touches Vidi.app or its TCC permissions — that's why it's isolated here.

## What was proven

1. **Voice processing turns on fine.** `inputNode.setVoiceProcessingEnabled(true)`
   succeeds; a VP mic engine with no playback starts cleanly.

2. **Rendering TTS *through* the VP engine is a hard NO-GO.** The instant a
   playback graph (player → mixer → output) is attached to the voice-processing
   engine, `engine.start()` fails with **`-10875` (kAudioUnitErr_FailedInitialization)**
   at `AudioUnitInitialize` on the output node. Tried VP-on-input-only, VP-on-both,
   explicit and implicit mixer→output reconnection — all fail identically.
   → The plan's original "single shared engine, TTS through its player node" cannot
   be built on this OS.

3. **The separate-engine design gets REAL hardware echo cancellation.**
   Design under test: a VP mic engine + the clip played through a *separate*
   `AVAudioPlayer` (exactly how Vidi's TTS plays). Measured, clip looping through
   the speakers the whole time:

   | phase | mic RMS (all channels) |
   |---|---|
   | SILENT (clip only, no human) | **0.0024** — echo cancelled |
   | SPEAKING (human over clip)   | **0.2238** — voice comes through (~90×) |

   macOS uses the **default output device** as the AEC reference, so a separate
   player's audio is cancelled from the mic in hardware. Barge-in works without a
   shared engine and without software echo hacks.

4. **Post-VP mic format is 48kHz `7ch`** (intrinsic to VPIO here, not a device
   artifact — the Maono virtual driver was fully removed and it persists). All 7
   channels mirror the same processed mono signal. **Tap channel 0.**

## Consequence for A1

- Build `VoiceConversationAudioEngine` on **separate engines**: VP mic engine
  (tap ch0) + TTS via a separate `AVAudioPlayer`. Do NOT render TTS through the VP
  engine.
- `voiceOutputEngineMode` collapses: separate-engines is primary and gets real
  AEC. Keep a software echo-filter only as a backup for Bluetooth/HFP outputs.

## Open item to verify in A1 (not a blocker)

- The harness's throwaway `SFSpeechRecognizer` printed **no transcript** despite
  clean, strong audio on ch0 (RMS 0.22). Likely a config detail of this tool
  (on-device flag / hand-built mono buffer), not the architecture — Vidi's real
  `AppleSpeechTranscriptionProvider` already transcribes this VP mic stream during
  PTT/hands-free. Confirm transcription on ch0 early in A1 before building on it.

## Re-run

From this directory, generate the playback clip (built-in macOS `say`), then
build and run the harness with plain `swiftc`:

```
say -o /tmp/aec-clip.aiff "the quick brown fox jumps over the lazy dog"
swiftc main.swift -o aec-spike && ./aec-spike
```

~13s total: PHASE 1 (4s) stay silent while the clip plays (measures whether the
echo canceller kills it), then PHASE 2 (9s) say "pineapple pineapple pineapple"
over the clip. It prints per-channel RMS live and ends with a RESULT block.
First run prompts once for microphone + speech-recognition access.
