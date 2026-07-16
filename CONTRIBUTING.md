# Contributing to Vidi

Thanks for helping. Vidi is a personal project maintained as time allows, so
reviews may be slow. Small, focused changes land fastest.

## Setup

```bash
# Worker
cd worker && npm install && npm test && npm run typecheck

# Mac app
open ../vidi.xcodeproj   # set signing team, Product → Test
```

Requires a recent Xcode and Node 22+ for the Worker.

## Ground rules

- **No telemetry reintroduction.** Analytics stay a no-op stub unless a future
  design explicitly opts users in.
- **No raw API keys in the app.** Provider credentials stay on the Worker.
- **Keep decision logic unit-testable.** Prefer pure helpers (like the wake/echo
  filters) over growing the large coordinator types without tests.
- **Preserve the clicky MIT attribution** in LICENSE and README fork notes.

## Sending a change

1. Fork and branch from `main`.
2. Keep Worker tests green (`cd worker && npm test`).
3. Open a PR with a short description of what changed and why.
