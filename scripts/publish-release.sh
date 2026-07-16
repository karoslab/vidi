#!/usr/bin/env bash
#
# publish-release.sh — ship a new vidi-chat release through the vidi-proxy
# release channel so an installed client can one-tap update.
#
# What it does:
#   1. `git archive` vidi-chat at a commit → gzip -9 → a .tar.gz
#   2. compute the sha-256 of that gzipped tarball
#   3. POST it (multipart) to the worker's admin-only /release/publish, which
#      stores the tarball + a manifest the client polls via /release/manifest
#
# The admin credential is read from the environment ($VIDI_ADMIN_KEY) — it is
# NEVER passed on the command line, echoed, or written to disk, and it is fed to
# curl through a stdin config file so it never appears in the process list.
#
# Usage:
#   VIDI_ADMIN_KEY=... scripts/publish-release.sh \
#     --sha <vidi-chat-commit> --version <version> --notes "<what's new>"
#
#   # Preview everything (build the tarball, show size + sha256) without POSTing:
#   scripts/publish-release.sh --sha <commit> --version <version> \
#     --notes "..." --dry-run
#
# Options:
#   --sha <commit>        vidi-chat commit (or ref) to archive           [required]
#   --version <string>    release version label (1-64 of A-Za-z0-9._-)  [required]
#   --notes <string>      plain-language "what's new"                    [default: ""]
#   --dry-run             build + hash only; do not POST                 [optional]
#   --worker-url <url>    override the worker base url                   [default below]
#   --vidi-chat-repo <p>  override the vidi-chat checkout path           [default below]
#   -h | --help           show this help
#
set -euo pipefail

DEFAULT_WORKER_URL="https://vidi-proxy.REPLACE-SUBDOMAIN.workers.dev"
DEFAULT_VIDI_CHAT_REPO="../vidi-chat"   # sibling checkout; override with --vidi-chat-repo

sha=""
version=""
notes=""
dryRun="false"
workerUrl="$DEFAULT_WORKER_URL"
vidiChatRepo="$DEFAULT_VIDI_CHAT_REPO"

fail() {
  echo "error: $*" >&2
  exit 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --sha)            sha="${2:-}"; shift 2 ;;
    --version)        version="${2:-}"; shift 2 ;;
    --notes)          notes="${2:-}"; shift 2 ;;
    --dry-run)        dryRun="true"; shift ;;
    --worker-url)     workerUrl="${2:-}"; shift 2 ;;
    --vidi-chat-repo) vidiChatRepo="${2:-}"; shift 2 ;;
    -h|--help)        sed -n '2,40p' "$0"; exit 0 ;;
    *)                fail "unknown argument: $1 (try --help)" ;;
  esac
done

[ -n "$sha" ] || fail "--sha is required (the vidi-chat commit to archive)"
[ -n "$version" ] || fail "--version is required"
# Mirror the worker's isValidReleaseVersion so a bad version fails locally, not
# after a full archive + upload.
echo "$version" | grep -Eq '^[A-Za-z0-9._-]{1,64}$' \
  || fail "--version must be 1-64 chars of letters, digits, . _ -"
[ -d "$vidiChatRepo/.git" ] || fail "not a git checkout: $vidiChatRepo"
git -C "$vidiChatRepo" rev-parse --verify --quiet "$sha^{commit}" >/dev/null \
  || fail "unknown commit/ref in $vidiChatRepo: $sha"

# The admin key is only required when we are actually going to POST.
if [ "$dryRun" != "true" ] && [ -z "${VIDI_ADMIN_KEY:-}" ]; then
  fail "VIDI_ADMIN_KEY is not set in the environment (required unless --dry-run)"
fi

# Resolve the exact commit so the manifest records the real sha even if --sha
# was a branch/tag.
resolvedSha="$(git -C "$vidiChatRepo" rev-parse "$sha")"

tarballPath="$(mktemp -t vidi-chat-release-XXXXXX.tar.gz)"
cleanup() { rm -f "$tarballPath"; }
trap cleanup EXIT

echo "Archiving vidi-chat @ ${resolvedSha:0:12} → stamp release.json → gzip -9 …" >&2
# Stamp release.json INSIDE the tarball: the committed file says {"version":"dev"}
# (a dev checkout keeps the updater off). An install that applied an unstamped
# tarball would become a "dev build" and disable its own updater — so the
# publish pipeline is where the real version/sha get written.
stageDir="$(mktemp -d -t vidi-chat-release-stage-XXXXXX)"
git -C "$vidiChatRepo" archive "$resolvedSha" | tar -x -C "$stageDir"
printf '{\n  "version": "%s",\n  "sha": "%s",\n  "builtAt": "%s"\n}\n' \
  "$version" "$resolvedSha" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$stageDir/release.json"
tar -czf "$tarballPath" -C "$stageDir" .
rm -rf "$stageDir"

tarballBytes="$(wc -c < "$tarballPath" | tr -d ' ')"
tarballSha256="$(shasum -a 256 "$tarballPath" | awk '{print $1}')"

echo "  version : $version" >&2
echo "  sha     : $resolvedSha" >&2
echo "  bytes   : $tarballBytes" >&2
echo "  sha256  : $tarballSha256" >&2

if [ "$dryRun" = "true" ]; then
  echo "[dry-run] built tarball, computed hash — not POSTing to $workerUrl/release/publish" >&2
  exit 0
fi

echo "Publishing to $workerUrl/release/publish …" >&2
# Feed the admin header via a stdin config file so the secret never lands in the
# process list / argv. `--fail-with-body` makes a non-2xx exit non-zero while
# still printing the worker's JSON error.
httpResponse="$(
  printf 'header = "x-vidi-admin-key: %s"\n' "$VIDI_ADMIN_KEY" \
    | curl --silent --show-error --fail-with-body \
        --config - \
        --form "version=$version" \
        --form "sha=$resolvedSha" \
        --form "notes=$notes" \
        --form "tarball=@${tarballPath};type=application/gzip;filename=vidi-chat-${version}.tar.gz" \
        "$workerUrl/release/publish"
)" || fail "publish failed: $httpResponse"

echo "$httpResponse"
echo "Published version $version." >&2
