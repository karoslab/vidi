#!/bin/bash
#
# Launch wrapper for the local Pocket TTS (Azelma) voice service.
#
# This is the ProgramArguments target of the com.vidi.pocket-tts launchd
# agent. It exists so the gated-weights Hugging Face token is read at RUNTIME
# from ~/.cache/huggingface/token (mode 600) and NEVER baked into the committed
# plist, the repo, or any argv list. The server binds 127.0.0.1 ONLY on the
# port persisted at install time (see install.sh / README.md).
#
set -euo pipefail

SUPPORT_DIR="$HOME/Library/Application Support/Vidi"
VENV_POCKET_TTS="$SUPPORT_DIR/pocket-tts-venv/bin/pocket-tts"
PORT_FILE="$SUPPORT_DIR/pocket-tts-port"

# Port precedence: explicit $1 (the plist passes it) → persisted port file →
# the documented default. All three resolve to the same 127.0.0.1-only bind.
CHOSEN_PORT="${1:-}"
if [ -z "$CHOSEN_PORT" ] && [ -f "$PORT_FILE" ]; then
  CHOSEN_PORT="$(cat "$PORT_FILE")"
fi
CHOSEN_PORT="${CHOSEN_PORT:-4192}"

# Weights already live in the default HF cache after install; keep HF_HOME there
# so the server loads from cache. Only supply the token so a gated RE-download
# can succeed if a cache file is ever missing. The token is never printed.
export HF_HOME="${HF_HOME:-$HOME/.cache/huggingface}"
TOKEN_FILE="$HOME/.cache/huggingface/token"
if [ -f "$TOKEN_FILE" ]; then
  HF_TOKEN="$(cat "$TOKEN_FILE")"
  export HF_TOKEN
fi

exec "$VENV_POCKET_TTS" serve \
  --host 127.0.0.1 \
  --port "$CHOSEN_PORT" \
  --language english
