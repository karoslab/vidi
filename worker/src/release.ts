/**
 * Vidi Proxy Worker — release channel (one-tap vidi-chat updates).
 *
 * The vidi-chat client polls this worker for the latest published release so a
 * user can update in one tap. Three routes (wired in index.ts):
 *
 *   GET  /release/manifest         → the published release's metadata (JSON)
 *   GET  /release/download/<ver>   → streams that version's gzipped tarball
 *   POST /release/publish          → admin-only: store a new tarball + manifest
 *
 * Storage: the tarball is a single gzipped `git archive` of vidi-chat. Measured
 * at ~7.7 MB (2026-07-12), comfortably under Cloudflare KV's 25 MB per-value
 * ceiling, so it is stored in the EXISTING `VIDI_KEYSET` KV namespace under a
 * `release:` key prefix — no new binding, nothing for the owner to create before
 * deploy. The keyset's own `list({ prefix: "id:" })` scans never touch these
 * keys, so the two concerns coexist in one namespace without interfering.
 *
 *   release:manifest          → the manifest JSON (version/sha/sha256/notes/publishedAt)
 *   release:tarball:<version> → the gzipped tarball bytes (ArrayBuffer)
 *   release:dl:<keyId>:<utc>  → per-install per-UTC-day download counter (rate limit)
 *
 * A manifest check and a download are BOTH excluded from the chat daily quota
 * (they are not proxied upstream calls); a download additionally carries its own
 * modest per-key daily rate limit so a client bug cannot hammer worker bandwidth.
 * The owner shared key is unmetered here exactly as it is everywhere else.
 */

// The `release:` KV keys hold a binary tarball, so this module needs a binding
// that can read/write an ArrayBuffer. It is the SAME physical binding as the
// keyset's `VIDI_KEYSET` (whose local interface is intentionally string-only);
// the real Cloudflare KVNamespace satisfies both, so index.ts passes the bound
// namespace in under this wider interface.
export interface VidiReleaseKVNamespace {
  get(key: string): Promise<string | null>;
  get(key: string, type: "arrayBuffer"): Promise<ArrayBuffer | null>;
  put(
    key: string,
    value: string | ArrayBuffer,
    options?: { expirationTtl?: number }
  ): Promise<void>;
  delete(key: string): Promise<void>;
}

/** The manifest as stored in KV and (minus the derived `url`) served to clients. */
export interface StoredReleaseManifest {
  version: string;
  sha: string; // the vidi-chat git commit the tarball was archived at
  sha256: string; // hex sha-256 of the gzipped tarball bytes
  notes: string; // plain-language "what's new"
  publishedAt: string; // ISO 8601, set server-side at publish time
}

// Per-install downloads allowed per UTC day. A one-tap update needs one
// download; this ceiling is generous enough for a few retries but low enough
// that a stuck client cannot drain bandwidth. The owner key is exempt.
export const DEFAULT_DAILY_DOWNLOAD_LIMIT = 20;

// Download counters live 2 days so "today" (UTC) is always readable and stale
// day-counters self-expire without a sweep (mirrors the chat usage counter TTL).
export const DOWNLOAD_COUNTER_TTL_SECONDS = 60 * 60 * 48;

export const MANIFEST_KV_NAME = "release:manifest";

export function tarballKvName(version: string): string {
  return `release:tarball:${version}`;
}

export function downloadCounterKvName(keyId: string, dateStamp: string): string {
  return `release:dl:${keyId}:${dateStamp}`;
}

/** `yyyy-mm-dd` in UTC — the bucket a download counter lives in. */
export function utcDownloadDateStamp(now: Date): string {
  return now.toISOString().slice(0, 10);
}

/** SHA-256 hex of raw bytes, via Web Crypto (Workers + Node 18+). */
export async function sha256HexOfBytes(bytes: ArrayBuffer): Promise<string> {
  const digestBuffer = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(digestBuffer)]
    .map((byteValue) => byteValue.toString(16).padStart(2, "0"))
    .join("");
}

/**
 * Whether a proposed `version` string is safe to use as a KV key segment and a
 * URL path segment. Restricted to a conservative set so a published version can
 * never smuggle a `/`, whitespace, or a `release:` key-prefix collision.
 */
export function isValidReleaseVersion(version: unknown): version is string {
  return typeof version === "string" && /^[A-Za-z0-9._-]{1,64}$/.test(version);
}

/** The absolute download URL a client should fetch, derived from the request origin. */
export function downloadUrlForVersion(requestOrigin: string, version: string): string {
  return `${requestOrigin}/release/download/${version}`;
}

export interface DownloadRateLimitDecision {
  allowed: boolean;
  usedDownloadsAfterThisOne: number;
  dailyDownloadLimit: number;
}

/**
 * Decide whether one more download is within the daily limit given how many have
 * already been recorded for the key today. Pure — no storage. Mirrors the shape
 * of keyset's `decideQuota` so the two rate limits read identically.
 */
export function decideDownloadRateLimit(
  downloadsAlreadyUsedToday: number,
  dailyDownloadLimit: number
): DownloadRateLimitDecision {
  const usedDownloadsAfterThisOne = downloadsAlreadyUsedToday + 1;
  return {
    allowed: usedDownloadsAfterThisOne <= dailyDownloadLimit,
    usedDownloadsAfterThisOne,
    dailyDownloadLimit,
  };
}

/**
 * KV-backed release operations. Thin wrapper over the (binary-capable) KV
 * binding — all decision logic lives in the pure helpers above so it is testable
 * with an in-memory KV stub, exactly like `KeysetStore`.
 */
export class ReleaseStore {
  constructor(private readonly releaseKV: VidiReleaseKVNamespace) {}

  /** Store a new release: its tarball bytes plus the manifest that points at it. */
  async publish(
    manifest: StoredReleaseManifest,
    tarballBytes: ArrayBuffer
  ): Promise<void> {
    await this.releaseKV.put(tarballKvName(manifest.version), tarballBytes);
    await this.releaseKV.put(MANIFEST_KV_NAME, JSON.stringify(manifest));
  }

  /** The currently-published manifest, or null when nothing has been published. */
  async getManifest(): Promise<StoredReleaseManifest | null> {
    const storedManifest = await this.releaseKV.get(MANIFEST_KV_NAME);
    return storedManifest
      ? (JSON.parse(storedManifest) as StoredReleaseManifest)
      : null;
  }

  /** The gzipped tarball bytes for a version, or null if that version is unknown. */
  async getTarball(version: string): Promise<ArrayBuffer | null> {
    return this.releaseKV.get(tarballKvName(version), "arrayBuffer");
  }

  /**
   * Record one download against a per-install per-UTC-day limit. Only increments
   * the counter when the download is within the limit, so the stored counter
   * caps at the limit. Read-modify-write on KV is not atomic; a brief concurrency
   * overshoot is acceptable for a bandwidth cap (same tradeoff as the chat quota).
   */
  async recordDownloadAndCheckLimit(
    keyId: string,
    now: Date,
    dailyDownloadLimit: number
  ): Promise<DownloadRateLimitDecision> {
    const counterName = downloadCounterKvName(keyId, utcDownloadDateStamp(now));
    const downloadsAlreadyUsedToday = parseInt(
      (await this.releaseKV.get(counterName)) || "0",
      10
    );
    const decision = decideDownloadRateLimit(
      downloadsAlreadyUsedToday,
      dailyDownloadLimit
    );
    if (decision.allowed) {
      await this.releaseKV.put(
        counterName,
        String(decision.usedDownloadsAfterThisOne),
        { expirationTtl: DOWNLOAD_COUNTER_TTL_SECONDS }
      );
    }
    return decision;
  }
}
