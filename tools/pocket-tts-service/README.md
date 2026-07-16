# Local Pocket TTS (Azelma) voice service

An optional, local, 127.0.0.1-only text-to-speech service for Vidi, using
Kyutai [Pocket TTS](https://github.com/kyutai-labs/pocket-tts) with the
**Azelma** voice. Vidi's default TTS is unchanged (Grok cloud); this service is
the alternative behind a default-off toggle. It stays default-off until
repeated on-device verification passes.

## Attribution (CC BY 4.0 — required)

Voice: **Azelma**, VCTK corpus (CC BY 4.0) via Kyutai Pocket TTS. The Azelma
voice is a cloned VCTK speaker (p303); the model weights are CC BY 4.0 with a
"no uncleared voice cloning" clause. Full license inventory: `./LICENSES.md`.

## Install

```
tools/pocket-tts-service/install.sh
```

Idempotent. It creates an isolated `uv` venv pinned to `requirements.lock.txt`,
downloads + SHA-256-verifies the gated weights and the Azelma voice into the
default Hugging Face cache, probes a free fixed 127.0.0.1 port (avoiding the
reserved local service ranges), persists it to
`~/Library/Application Support/Vidi/pocket-tts-port`, and loads the
`com.vidi.pocket-tts` launchd agent (KeepAlive, 127.0.0.1 bind only).

The gated-weights HF token is read at runtime from `~/.cache/huggingface/token`
(mode 600) and never printed, committed, or written into the plist.

## Enable in Vidi (default is Grok cloud)

```
defaults write com.example.vidi vidiLocalVoiceEnabled -bool YES   # then relaunch Vidi
```

Turn it back off (rollback):

```
defaults delete com.example.vidi vidiLocalVoiceEnabled            # then relaunch Vidi
```

With the toggle on, Vidi runs a fast health probe per utterance batch and uses
the local voice when the service answers; on any local failure it falls back to
Grok cloud, then to on-device `AVSpeechSynthesizer` — Vidi is never left mute.
The default does NOT flip to local until repeated on-device verification passes.

Optional port override (normally unnecessary — the app reads the persisted
port file):

```
defaults write com.example.vidi vidiLocalVoicePort 4192           # then relaunch Vidi
```

## Smoke test

```
curl -fsS http://127.0.0.1:$(cat ~/Library/Application\ Support/Vidi/pocket-tts-port)/health   # 200 when ready
swift tools/pocket-tts-service/smoke-local-voice.swift            # end-to-end through the app code path
```

The smoke synthesizes one sentence through the same request + WAV-temp-file +
`AVAudioFile` decode path the app uses and reports measured first-audio latency.

## Uninstall (full removal)

```
tools/pocket-tts-service/uninstall.sh
```

Removes the launchd agent, venv, wrapper, port file, and logs. Leaves the
shared HF model cache in place (delete `~/.cache/huggingface` by hand to reclaim
the ~222 MB). Vidi returns to Grok cloud automatically.

## Notes

- Server contract (pinned pocket-tts 2.1.0): `POST /tts` multipart form
  `text` + `voice_url=azelma`, returns chunked `audio/wav` (mono 16-bit
  24 kHz, with a 200 ms trailing-silence tail the app trims). Health: `GET
  /health`.
- Footprint: ~719 MB venv + ~222 MB weights.
- Health: this is a localhost-only service (bind 127.0.0.1 only).
