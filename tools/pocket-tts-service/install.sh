#!/bin/bash
#
# Idempotent installer for the local Pocket TTS (Azelma) voice service.
#
# What it does (safe to re-run):
#   1. Creates an isolated uv venv pinned EXACTLY to requirements.lock.txt.
#   2. Downloads + SHA-256-verifies the gated weights and the pinned Azelma
#      voice into the default Hugging Face cache (token read at runtime only,
#      never printed/committed).
#   3. Probes a free fixed 127.0.0.1 port (avoiding the reserved local
#      ranges), persists it where the Vidi app reads it.
#   4. Writes + loads the com.vidi.pocket-tts launchd agent (KeepAlive,
#      Interactive ProcessType, 127.0.0.1 bind only) and health-checks /health.
#      The plist is rewritten and re-loaded (bootout + bootstrap + kickstart) on
#      EVERY run, so an existing install picks up plist changes (e.g. the
#      ProcessType bump) in place — just re-run this script.
#
# Uninstall with uninstall.sh (fully removes the service; leaves the shared HF
# model cache in place). See README.md for the runbook + toggle.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUPPORT_DIR="$HOME/Library/Application Support/Vidi"
SERVICE_DIR="$SUPPORT_DIR/pocket-tts"
VENV_DIR="$SUPPORT_DIR/pocket-tts-venv"
PORT_FILE="$SUPPORT_DIR/pocket-tts-port"
PLIST_LABEL="com.vidi.pocket-tts"
PLIST_PATH="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"
LOG_DIR="$HOME/Library/Logs"
WRAPPER_INSTALLED="$SERVICE_DIR/run-pocket-tts.sh"

# Pins (verified 2026-07-10).
POCKET_WEIGHTS_REPO="kyutai/pocket-tts"
POCKET_WEIGHTS_REV="39592ff23c9ef80098bb74895d104c26275fe2c9"
POCKET_WEIGHTS_FILE="languages/english/model.safetensors"
POCKET_WEIGHTS_SHA256="473f47d99560bd50eb8b4509d3cacfe7f316ab20bdca86505403a2e6a936a6e9"
VOICES_REPO="kyutai/tts-voices"
AZELMA_VOICE_FILE="vctk/p303_023_enhanced.wav"
AZELMA_VOICE_SHA256="60e3d26cdf2efdec5df712152c839928f4d5522821e6554ae11fd96c57ab1026"

log() { printf '[pocket-tts install] %s\n' "$1"; }

# ---------------------------------------------------------------------------
# 0. Preconditions
# ---------------------------------------------------------------------------
if ! command -v uv >/dev/null 2>&1; then
  echo "ERROR: uv is not installed (need it for the isolated pinned venv)." >&2
  echo "Install uv from https://docs.astral.sh/uv/ and re-run." >&2
  exit 1
fi

mkdir -p "$SUPPORT_DIR" "$SERVICE_DIR" "$LOG_DIR" "$HOME/Library/LaunchAgents"

# ---------------------------------------------------------------------------
# 1. Isolated venv pinned to the lock
# ---------------------------------------------------------------------------
if [ ! -x "$VENV_DIR/bin/pocket-tts" ]; then
  log "creating isolated venv at $VENV_DIR"
  uv venv --python 3.12 "$VENV_DIR"
  log "installing pinned requirements (this pulls torch — a few minutes)"
  uv pip install --python "$VENV_DIR/bin/python" -r "$SCRIPT_DIR/requirements.lock.txt"
else
  log "venv already present — skipping create/install"
fi

# ---------------------------------------------------------------------------
# 2. Download + verify the gated weights and the Azelma voice
# ---------------------------------------------------------------------------
# The token is read from the file the user authorized and passed ONLY as an env
# var to this one python subprocess. It is never echoed or written anywhere.
TOKEN_FILE="$HOME/.cache/huggingface/token"
if [ -f "$TOKEN_FILE" ]; then
  HF_TOKEN="$(cat "$TOKEN_FILE")"
  export HF_TOKEN
fi
export HF_HOME="${HF_HOME:-$HOME/.cache/huggingface}"

log "resolving + verifying weights and Azelma voice (downloads on first run)"
"$VENV_DIR/bin/python" - "$POCKET_WEIGHTS_REPO" "$POCKET_WEIGHTS_REV" \
  "$POCKET_WEIGHTS_FILE" "$POCKET_WEIGHTS_SHA256" \
  "$VOICES_REPO" "$AZELMA_VOICE_FILE" "$AZELMA_VOICE_SHA256" <<'PYEOF'
import hashlib
import sys
from huggingface_hub import hf_hub_download

(weights_repo, weights_rev, weights_file, weights_sha,
 voices_repo, voice_file, voice_sha) = sys.argv[1:8]


def sha256_of(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def resolve_and_verify(repo, revision, filename, expected_sha, label):
    local_path = hf_hub_download(repo_id=repo, filename=filename, revision=revision)
    actual_sha = sha256_of(local_path)
    if actual_sha != expected_sha:
        raise SystemExit(
            f"SHA-256 MISMATCH for {label}\n  expected {expected_sha}\n  actual   {actual_sha}")
    print(f"  verified {label}: sha256 ok")


resolve_and_verify(weights_repo, weights_rev, weights_file, weights_sha, "gated weights")
# The voices repo is not gated and not revision-pinned in config; verify by file SHA.
resolve_and_verify(voices_repo, None, voice_file, voice_sha, "Azelma voice")
print("  all artifacts verified")
PYEOF

# ---------------------------------------------------------------------------
# 3. Probe a free fixed 127.0.0.1 port and persist it
# ---------------------------------------------------------------------------
if [ -f "$PORT_FILE" ] && [ -s "$PORT_FILE" ]; then
  CHOSEN_PORT="$(cat "$PORT_FILE")"
  log "reusing persisted port $CHOSEN_PORT"
else
  CHOSEN_PORT="$("$VENV_DIR/bin/python" - <<'PYEOF'
import socket

# Reserved ranges to avoid (local services + common dev ports).
reserved = set([3000, 3100, 8000, 8001])
reserved |= set(range(4173, 4188))   # 4173-4187 (game previews + hands/vidi-chat)
reserved |= set(range(63000, 64000)) # 63xxx

def free(port: int) -> bool:
    if port in reserved:
        return False
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            probe.bind(("127.0.0.1", port))
            return True
        except OSError:
            return False

for candidate in [4192, 4193, 4194, 4195, 4196, 4197, 4198, 4199, 4290, 5202, 5252]:
    if free(candidate):
        print(candidate)
        break
else:
    raise SystemExit("no free candidate port found")
PYEOF
)"
  printf '%s' "$CHOSEN_PORT" > "$PORT_FILE"
  log "chose free port $CHOSEN_PORT (persisted to $PORT_FILE)"
fi

# ---------------------------------------------------------------------------
# 4. Install the launch wrapper + launchd agent, load, health-check
# ---------------------------------------------------------------------------
cp "$SCRIPT_DIR/run-pocket-tts.sh" "$WRAPPER_INSTALLED"
chmod +x "$WRAPPER_INSTALLED"

cat > "$PLIST_PATH" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$PLIST_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$WRAPPER_INSTALLED</string>
        <string>$CHOSEN_PORT</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <!-- Interactive: latency-sensitive streaming voice synthesis. Under a loaded
         Mac the default Adaptive class let the service fall to RTF 0.72 (~1.4x
         realtime) and the stream lane fell progressively behind, stalling
         playback mid-sentence. Interactive keeps synthesis scheduled ahead of
         background work so first audio stays snappy and the lane keeps up. -->
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardOutPath</key>
    <string>$LOG_DIR/pocket-tts.out.log</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/pocket-tts.err.log</string>
</dict>
</plist>
PLISTEOF

log "loading launchd agent $PLIST_LABEL"
launchctl bootout "gui/$(id -u)/$PLIST_LABEL" 2>/dev/null || true

# Bootstrap RETRY (race-proofing): a bootout→bootstrap done back-to-back can lose
# a race against launchd's own teardown of the just-booted-out service ("Bootstrap
# failed: 5: Input/output error") and strand the service unloaded. Retry up to 5
# times, 1s apart, tolerating the failure instead of exiting on the first miss.
BOOTSTRAPPED=0
for attempt in $(seq 1 5); do
  if launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH" 2>/dev/null; then
    BOOTSTRAPPED=1
    log "bootstrap succeeded (attempt $attempt)"
    break
  fi
  log "bootstrap attempt $attempt failed — retrying in 1s"
  sleep 1
done

if [ "$BOOTSTRAPPED" != "1" ]; then
  echo "ERROR: launchctl bootstrap did not succeed after 5 attempts; service is NOT loaded." >&2
  exit 1
fi

launchctl kickstart -k "gui/$(id -u)/$PLIST_LABEL" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 5. Verify the service actually came up (cold model load can take up to ~10s
#    on first weight load) before this script exits 0.
# ---------------------------------------------------------------------------
HEALTH_URL="http://127.0.0.1:$CHOSEN_PORT/health"
log "waiting for $HEALTH_URL"
READY=0
for _ in $(seq 1 120); do
  if curl -fsS --max-time 2 "$HEALTH_URL" >/dev/null 2>&1; then
    READY=1
    break
  fi
  sleep 1
done

if [ "$READY" != "1" ]; then
  echo "ERROR: service did not report healthy in time; check $LOG_DIR/pocket-tts.err.log" >&2
  exit 1
fi

if ! launchctl print "gui/$(id -u)/$PLIST_LABEL" >/dev/null 2>&1; then
  echo "ERROR: service passed the health check but launchctl print can't find it; check $LOG_DIR/pocket-tts.err.log" >&2
  exit 1
fi

log "SERVICE HEALTHY on 127.0.0.1:$CHOSEN_PORT"
log "enable in Vidi: defaults write com.example.vidi vidiLocalVoiceEnabled -bool YES  (then relaunch)"
