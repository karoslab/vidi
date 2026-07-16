# Vidi

*veni, vidi — it sees your screen and talks back.*

Vidi is a Jarvis-style AI companion that lives in the macOS menu bar. Hold
**Ctrl + Option** anywhere, ask a question out loud, release — Vidi looks at
your screen(s), answers in a natural voice, and can fly a blue cursor across
the screen to point at the exact UI element it's talking about.

Forked from [farzaa/clicky](https://github.com/farzaa/clicky) (MIT), then
rebranded, hardened, and rewired as a local-first companion.

## How it works

```
Ctrl+Option (hold)          release
     │                          │
     ▼                          ▼
 mic capture ──► Apple on-device speech-to-text (free, local)
                                │ transcript
                                ▼
      screenshots of all displays + transcript
                                │
                                ▼
              vidi-proxy (Cloudflare Worker, auth'd)
                 /chat ──► OpenAI-compatible vision chat (OpenAI or Grok)
                           selectable server-side via CHAT_PROVIDER
                 /tts  ──► Grok TTS (default) — ElevenLabs optional
                                │  SSE stream + audio
                                ▼
        spoken answer + [POINT:x,y] cursor fly-to on any monitor
        (falls back to on-device Mac voice if TTS is unreachable)
```

Start with **"vidi, …"** ("hey vidi" / "ok vidi" work too) and the turn skips
the screen pipeline — no screenshots; the command goes to the local vidi-chat
agent (`http://127.0.0.1:4183/api/voice-command`), which does the work and
streams back a result that Vidi speaks.

All API keys live on the Worker as Cloudflare secrets — nothing sensitive in
the app. Every Worker route (except `GET /` health) requires the `x-vidi-key`
shared secret, so strangers can't burn API credits.

## Differences from upstream clicky

- **Renamed** everything to Vidi (Xcode target `vidi`; set your own bundle id
  and signing team in Xcode before shipping a build).
- **Worker auth** — `x-vidi-key` shared secret + model allowlist + max_tokens cap.
- **Grok TTS** as the default voice; ElevenLabs path kept but optional.
- **On-device fallback voice** — if TTS fails you still hear the actual answer
  (upstream's fallback played a promo clip instead of the answer).
- **Telemetry stripped** — upstream shipped full transcripts + AI responses to
  the author's PostHog, emails to his FormSpark, and could auto-update itself
  from his GitHub via Sparkle. All removed (analytics is a no-op stub).
- **Apple on-device speech-to-text** by default — zero keys; AssemblyAI
  streaming still wired if you want it (`VoiceTranscriptionProvider` in Info.plist).
- **Models** — OpenAI-compatible `/chat` on the Worker; provider selected
  server-side via `CHAT_PROVIDER` (OpenAI or Grok).
- Onboarding flow bypassed; dead upstream code paths removed.

## Architecture

Three pieces; the only thing you run beyond the Mac app is a Cloudflare Worker:

- **macOS menu-bar app** (`vidi/`, SwiftUI + AppKit) — status-bar only
  (`LSUIElement`, no dock icon). Push-to-talk (Ctrl+Option) and an optional
  hands-free wake word capture voice; Apple Speech transcribes on-device;
  ScreenCaptureKit grabs all displays; a transparent overlay flies the blue
  cursor to `[POINT:x,y]` targets. TTS plays through a warm audio-engine queue
  with an on-device `AVSpeechSynthesizer` fallback so answers are never lost.
- **vidi-proxy Worker** (`worker/`, Cloudflare) — the only place API keys live.
  Every route except `GET /` health requires the `x-vidi-key` shared secret and
  enforces a model allowlist + `max_tokens` cap. Optional per-install keyset
  with daily quotas for multi-machine installs.
- **Local vidi-chat agent** (`127.0.0.1:4183`) — a `vidi, …` command skips the
  screen pipeline and POSTs to `/api/voice-command`; the agent does the work and
  streams back a result Vidi speaks. Optional; only wake-word commands use it.
  See the companion repo: [karoslab/vidi-chat](https://github.com/karoslab/vidi-chat).

There is no telemetry and no auto-update — both were stripped from upstream.

## Setup

Three steps: stand up the Worker, point the app at it, then build in Xcode.

```bash
# 1. Worker (needs Cloudflare login once)
cd worker && npm install
npx wrangler login
npx wrangler secret put OPENAI_API_KEY        # platform.openai.com (chat brain)
npx wrangler secret put XAI_API_KEY           # console.x.ai (Grok TTS + Grok brain)
npx wrangler secret put VIDI_PROXY_KEY        # long random string; app sends the same value
npx wrangler deploy                            # note the workers.dev URL

# 2. Point the app at your Worker
#    edit vidi/VidiConfig.swift → workerBaseURL (replace REPLACE-SUBDOMAIN)

# 3. Build
open vidi.xcodeproj   # set your signing team + bundle id, then Cmd+R
```

Optional: set `vidiChatControlTokenPath` (UserDefaults) if your vidi-chat
control-token file is not at the default under Application Support.

First launch asks for Microphone, Accessibility, Screen Recording, and Screen
Content permissions — grant all four. The app may register as a login item
(remove in System Settings → Login Items if unwanted).

## Optional local project aliases

Spoken "open \<name\>" for local **web consoles** (not `.app` bundles) can be
mapped in:

`~/Library/Application Support/Vidi/app-aliases.txt`

```
# name = url
My Dashboard = http://127.0.0.1:3000
```

Built-in: `vidi chat` / `vidi-chat` → `http://localhost:4183`.

## Development

```bash
# Worker unit tests
cd worker && npm install && npm test

# Swift unit tests: open vidi.xcodeproj in Xcode → Product → Test
```

## Contributing and security

- [CONTRIBUTING.md](CONTRIBUTING.md)
- [SECURITY.md](SECURITY.md)

## License

MIT. See [LICENSE](LICENSE). Upstream clicky is MIT; dual copyright retained.
