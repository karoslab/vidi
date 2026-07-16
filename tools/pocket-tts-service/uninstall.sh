#!/bin/bash
#
# Full uninstall of the local Pocket TTS (Azelma) voice service.
#
# Removes the launchd agent, the isolated venv, the launch wrapper, the port
# file, and the logs. Leaves the shared Hugging Face model cache
# (~/.cache/huggingface) alone — it is user cache, may be shared, and a
# re-download is costly; delete it by hand if you want the ~222MB back.
#
# This is the rollback half of the local-voice toggle: turn the toggle off in
# Vidi (defaults delete com.example.vidi vidiLocalVoiceEnabled) and run this.
#
set -euo pipefail

SUPPORT_DIR="$HOME/Library/Application Support/Vidi"
SERVICE_DIR="$SUPPORT_DIR/pocket-tts"
VENV_DIR="$SUPPORT_DIR/pocket-tts-venv"
PORT_FILE="$SUPPORT_DIR/pocket-tts-port"
PLIST_LABEL="com.vidi.pocket-tts"
PLIST_PATH="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"
LOG_DIR="$HOME/Library/Logs"

log() { printf '[pocket-tts uninstall] %s\n' "$1"; }

log "unloading launchd agent"
launchctl bootout "gui/$(id -u)/$PLIST_LABEL" 2>/dev/null || true

log "removing agent plist, venv, wrapper, port file, logs"
rm -f "$PLIST_PATH"
rm -rf "$VENV_DIR"
rm -rf "$SERVICE_DIR"
rm -f "$PORT_FILE"
rm -f "$LOG_DIR/pocket-tts.out.log" "$LOG_DIR/pocket-tts.err.log"

log "done. The shared HF model cache (~/.cache/huggingface) was left in place."
log "Vidi falls back to Grok cloud TTS automatically once the service is gone."
