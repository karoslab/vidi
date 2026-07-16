/**
 * Vidi Proxy Worker
 *
 * Proxies requests to the chat brain (OpenAI or Grok), TTS (Grok or
 * ElevenLabs), and AssemblyAI so the app never ships with raw API keys.
 * Keys are stored as Cloudflare secrets.
 *
 * Routes:
 *   GET  /                 → health check (no auth, used by uptime gate)
 *   POST /chat             → OpenAI-compatible chat completions (streaming,
 *                            model allowlist; provider picked by CHAT_PROVIDER)
 *   POST /tts              → Grok TTS (default) or ElevenLabs TTS. Honors an
 *                            optional per-request `voiceId`: an explicit id →
 *                            else the key's default voice → else the global
 *                            TTS_PROVIDER/*_VOICE_ID vars (byte-identical for
 *                            callers that never send a voiceId). A keyset key may
 *                            only select a voiceId it is entitled to (the stock
 *                            Grok voices, or its own allowedVoiceIds); the owner
 *                            key is unrestricted.
 *   GET  /voices           → the voices THIS key may use (id + label), for the
 *                            vidi-chat settings picker (auth: x-vidi-key, unmetered)
 *   POST /transcribe       → Grok (xAI) batch speech-to-text (multipart audio
 *                            in → transcript JSON out)
 *   POST /transcribe-sarvam → Sarvam batch speech-to-text (India-specialized,
 *                            en-IN accent; multipart audio in → transcript JSON out)
 *   POST /transcribe-token → AssemblyAI short-lived streaming token
 *
 *   Admin (owner-only, `x-vidi-admin-key`; A2 per-install keyset):
 *   POST /admin/keys        → issue a per-install key (returns the raw key once;
 *                            accepts optional allowedVoiceIds/defaultVoiceId)
 *   POST /admin/keys/update → update an existing key's label/quota/voice
 *                            entitlements (by keyId or unique label)
 *   POST /admin/keys/revoke → revoke a key by keyId
 *   GET  /admin/keys        → list keys with today's usage
 *
 * Every proxied POST route requires the `x-vidi-key` header. It is accepted
 * when it either equals the owner's shared `VIDI_PROXY_KEY` (unmetered — this
 * is the LIVE Mac app's key, kept working unchanged) OR, when a `VIDI_KEYSET`
 * KV binding is present, matches a per-install key that is not revoked and is
 * within its daily quota.
 */

import {
  INSTALL_KEY_PREFIX,
  DEFAULT_DAILY_QUOTA_REQUESTS,
  KeysetStore,
  constantTimeEquals,
  type InstallKeyRecord,
  type VidiKeysetKVNamespace,
} from "./keyset";
import {
  catalogForKey,
  resolveVoiceSelection,
  validateEntitlementSelection,
} from "./voices";
import {
  buildFeedbackDiscordContent,
  feedbackDateStamp,
  isFeedbackKind,
  weekStamp,
  MAX_FEEDBACK_BODY_BYTES,
  FEEDBACK_DAILY_CAP,
  WEEKLY_SUMMARY_WEEKLY_CAP,
  type FeedbackKind,
} from "./feedback";
import {
  ReleaseStore,
  DEFAULT_DAILY_DOWNLOAD_LIMIT,
  downloadUrlForVersion,
  isValidReleaseVersion,
  sha256HexOfBytes,
  type StoredReleaseManifest,
  type VidiReleaseKVNamespace,
} from "./release";

interface Env {
  OPENAI_API_KEY?: string;
  XAI_API_KEY?: string;
  SARVAM_API_KEY?: string;
  ELEVENLABS_API_KEY?: string;
  ASSEMBLYAI_API_KEY?: string;
  VIDI_PROXY_KEY: string;
  CHAT_PROVIDER?: string;
  CHAT_MODEL_ALLOWLIST?: string;
  TTS_PROVIDER?: string;
  GROK_VOICE_ID?: string;
  ELEVENLABS_VOICE_ID?: string;
  // A2 per-install keyset. Optional: when unset, only the owner shared key is
  // accepted (exactly today's behavior). When set, per-install keys also work.
  VIDI_ADMIN_KEY?: string;
  VIDI_KEYSET?: VidiKeysetKVNamespace;
  // Discord webhook the /feedback route forwards user-triggered feedback + the
  // consented weekly health summary to. Unset → /feedback 503s (no upstream
  // fetch). Never echoed back to a caller.
  VIDI_FEEDBACK_WEBHOOK?: string;
}

/**
 * Which credential authorized a proxied request. The owner (shared VIDI_PROXY_KEY)
 * is unrestricted; a keyset install carries its record so voice entitlements can
 * be enforced per install.
 */
type ProxyAuthContext =
  | { isOwner: true }
  | { isOwner: false; installKeyRecord: InstallKeyRecord };

// Used when the CHAT_MODEL_ALLOWLIST var is unset — mirrors wrangler.toml.
const DEFAULT_CHAT_MODEL_ALLOWLIST = "gpt-5.2,gpt-4.1-mini,grok-4.1,grok-4.1-fast";

const MAX_TOKENS_CAP = 2048;
const DEFAULT_MAX_COMPLETION_TOKENS = 1024;

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    // Unauthenticated health check for the uptime gate.
    if (request.method === "GET" && url.pathname === "/") {
      return new Response("vidi-proxy ok", { status: 200 });
    }

    // Owner-only admin surface for the per-install keyset (its own auth header).
    if (url.pathname.startsWith("/admin/")) {
      return await handleAdmin(request, env, url);
    }

    // Release channel (one-tap vidi-chat updates). Manifest/download are authed
    // by an install key but excluded from the chat quota; publish is admin-only.
    if (
      url.pathname === "/release/manifest" ||
      url.pathname === "/release/publish" ||
      url.pathname.startsWith("/release/download/")
    ) {
      return await handleRelease(request, env, url);
    }

    // Voice catalog for the settings picker — authed by x-vidi-key but NOT
    // metered against the daily quota (it is cache-friendly reference data, not
    // a proxied upstream call).
    if (request.method === "GET" && url.pathname === "/voices") {
      const catalogAuthorization = await authorizeProxyRequest(request, env, {
        meterUsage: false,
      });
      if (!catalogAuthorization.ok) {
        return catalogAuthorization.response;
      }
      return handleVoicesCatalog(env, catalogAuthorization.auth);
    }

    if (request.method !== "POST") {
      return new Response("Method not allowed", { status: 405 });
    }

    // Feedback relay — authed by x-vidi-key but NOT metered against the chat
    // quota; it enforces its OWN light per-key send cap (see handleFeedback).
    if (url.pathname === "/feedback") {
      const feedbackAuthorization = await authorizeProxyRequest(request, env, {
        meterUsage: false,
      });
      if (!feedbackAuthorization.ok) {
        return feedbackAuthorization.response;
      }
      return await handleFeedback(request, env, feedbackAuthorization.auth);
    }

    const proxyAuthorization = await authorizeProxyRequest(request, env);
    if (!proxyAuthorization.ok) {
      return proxyAuthorization.response;
    }

    try {
      if (url.pathname === "/chat") {
        return await handleChat(request, env);
      }

      if (url.pathname === "/tts") {
        return await handleTTS(request, env, proxyAuthorization.auth);
      }

      if (url.pathname === "/transcribe") {
        return await handleTranscribe(request, env);
      }

      if (url.pathname === "/transcribe-sarvam") {
        return await handleTranscribeSarvam(request, env);
      }

      if (url.pathname === "/transcribe-token") {
        return await handleTranscribeToken(env);
      }
    } catch (error) {
      console.error(`[${url.pathname}] Unhandled error:`, error);
      return jsonError(String(error), 500);
    }

    return new Response("Not found", { status: 404 });
  },
};

function jsonError(message: string, status: number): Response {
  return new Response(
    JSON.stringify({ error: message }),
    { status, headers: { "content-type": "application/json" } }
  );
}

function jsonResponse(payload: unknown, status: number): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { "content-type": "application/json" },
  });
}

/**
 * Authorize a proxied request. The owner's shared `VIDI_PROXY_KEY` always works
 * and is unmetered (backwards compatibility with the live Mac app). When a
 * `VIDI_KEYSET` KV binding is present, a per-install key is also accepted if it
 * is known, not revoked, and within its daily quota — and its usage is metered.
 * When no keyset is bound, behavior is identical to the original single-key
 * check (only the owner key works, same 401).
 */
async function authorizeProxyRequest(
  request: Request,
  env: Env,
  options: { meterUsage?: boolean } = {}
): Promise<
  | { ok: true; auth: ProxyAuthContext }
  | { ok: false; response: Response }
> {
  const meterUsage = options.meterUsage !== false;
  const providedProxyKey = request.headers.get("x-vidi-key") || "";

  // Owner shared key: unmetered, unchanged. This is the key compiled into the
  // live app; keeping it working before/during/after migration is the top
  // constraint.
  if (
    env.VIDI_PROXY_KEY &&
    constantTimeEquals(providedProxyKey, env.VIDI_PROXY_KEY)
  ) {
    return { ok: true, auth: { isOwner: true } };
  }

  // Per-install keys, only when the keyset store is bound.
  if (env.VIDI_KEYSET && providedProxyKey.startsWith(INSTALL_KEY_PREFIX)) {
    const keysetStore = new KeysetStore(env.VIDI_KEYSET);
    const installKeyRecord = await keysetStore.lookupByRawKey(providedProxyKey);
    if (!installKeyRecord || installKeyRecord.revoked) {
      return {
        ok: false,
        response: jsonError(
          "Unauthorized: unknown or revoked install key",
          401
        ),
      };
    }
    // Metered routes (the proxied upstream calls) record usage and enforce the
    // daily quota; the /voices catalog passes meterUsage:false to skip both.
    if (meterUsage) {
      const quotaDecision = await keysetStore.recordUsageAndCheckQuota(
        installKeyRecord,
        new Date()
      );
      if (!quotaDecision.allowed) {
        return {
          ok: false,
          response: jsonError(
            `Daily quota exceeded (${quotaDecision.dailyQuotaRequests} requests/day). It resets at UTC midnight.`,
            429
          ),
        };
      }
    }
    return { ok: true, auth: { isOwner: false, installKeyRecord } };
  }

  return {
    ok: false,
    response: jsonError("Unauthorized: missing or invalid x-vidi-key header", 401),
  };
}

/**
 * Owner-only keyset administration. Authenticated by `x-vidi-admin-key`, which
 * must equal the dedicated `VIDI_ADMIN_KEY` secret when set, else the owner's
 * `VIDI_PROXY_KEY` (so no new secret is required to start using it — the owner
 * proxy key already grants unmetered full access, so it grants no new privilege
 * here). Never accepts a per-install key.
 */
async function handleAdmin(
  request: Request,
  env: Env,
  url: URL
): Promise<Response> {
  const expectedAdminKey = env.VIDI_ADMIN_KEY || env.VIDI_PROXY_KEY;
  const providedAdminKey = request.headers.get("x-vidi-admin-key") || "";
  if (
    !expectedAdminKey ||
    !constantTimeEquals(providedAdminKey, expectedAdminKey)
  ) {
    return jsonError(
      "Unauthorized: missing or invalid x-vidi-admin-key header",
      401
    );
  }

  if (!env.VIDI_KEYSET) {
    return jsonError(
      "Keyset storage is not configured (VIDI_KEYSET KV binding missing)",
      503
    );
  }
  const keysetStore = new KeysetStore(env.VIDI_KEYSET);

  try {
    if (request.method === "POST" && url.pathname === "/admin/keys") {
      let adminRequestBody: Record<string, unknown> = {};
      try {
        adminRequestBody = (await request.json()) as Record<string, unknown>;
      } catch {
        adminRequestBody = {};
      }
      const label =
        typeof adminRequestBody.label === "string" &&
        adminRequestBody.label.trim().length > 0
          ? adminRequestBody.label.trim()
          : "unnamed-install";
      const dailyQuotaRequestsFieldValue = adminRequestBody.dailyQuotaRequests;
      let dailyQuotaRequests: number;
      if (
        dailyQuotaRequestsFieldValue === undefined ||
        dailyQuotaRequestsFieldValue === null
      ) {
        dailyQuotaRequests = DEFAULT_DAILY_QUOTA_REQUESTS;
      } else if (
        typeof dailyQuotaRequestsFieldValue === "number" &&
        Number.isInteger(dailyQuotaRequestsFieldValue) &&
        dailyQuotaRequestsFieldValue >= 1
      ) {
        dailyQuotaRequests = dailyQuotaRequestsFieldValue;
      } else {
        // A fractional/zero/negative/non-numeric quota used to silently
        // Math.floor() to a smaller (sometimes 0) value — a 0 quota mints a
        // key that 429s on its very first request. Reject instead so a typo
        // never mints a dead key.
        return jsonError(
          'Invalid "dailyQuotaRequests": must be an integer >= 1 when provided',
          400
        );
      }
      // Optional per-voice entitlements at mint time.
      const parsedEntitlements = parseVoiceEntitlementFields(adminRequestBody);
      if ("error" in parsedEntitlements) {
        return jsonError(parsedEntitlements.error, 400);
      }
      const entitlementValidationError = validateEntitlementSelection(
        parsedEntitlements.allowedVoiceIds,
        parsedEntitlements.defaultVoiceId
      );
      if (entitlementValidationError) {
        return jsonError(entitlementValidationError, 400);
      }

      const { rawKey, record } = await keysetStore.issueInstallKey(
        label,
        dailyQuotaRequests,
        {
          allowedVoiceIds: parsedEntitlements.allowedVoiceIds,
          defaultVoiceId: parsedEntitlements.defaultVoiceId,
        }
      );
      // The raw key is returned exactly once — it is never stored or logged.
      return jsonResponse(
        {
          key: rawKey,
          keyId: record.keyId,
          label: record.label,
          dailyQuotaRequests: record.dailyQuotaRequests,
          allowedVoiceIds: record.allowedVoiceIds ?? [],
          defaultVoiceId: record.defaultVoiceId ?? null,
          createdAt: record.createdAt,
        },
        201
      );
    }

    if (request.method === "POST" && url.pathname === "/admin/keys/update") {
      return await handleAdminKeysUpdate(request, keysetStore);
    }

    if (request.method === "POST" && url.pathname === "/admin/keys/revoke") {
      let revokeRequestBody: Record<string, unknown> = {};
      try {
        revokeRequestBody = (await request.json()) as Record<string, unknown>;
      } catch {
        revokeRequestBody = {};
      }
      const keyId =
        typeof revokeRequestBody.keyId === "string"
          ? revokeRequestBody.keyId
          : "";
      if (!keyId) {
        return jsonError('Missing required field "keyId"', 400);
      }
      const wasRevoked = await keysetStore.revokeByKeyId(keyId);
      return wasRevoked
        ? jsonResponse({ revoked: true, keyId }, 200)
        : jsonError("No install key with that keyId", 404);
    }

    if (request.method === "GET" && url.pathname === "/admin/keys") {
      const keys = await keysetStore.listKeys(new Date());
      return jsonResponse({ keys }, 200);
    }
  } catch (error) {
    console.error(`[${url.pathname}] Admin error:`, error);
    return jsonError(String(error), 500);
  }

  return jsonError("Not found", 404);
}

/**
 * Release channel dispatcher. Shares the `VIDI_KEYSET` KV binding (the tarball
 * fits under KV's 25 MB per-value ceiling — see release.ts), so a missing keyset
 * binding 503s here exactly as it does for the admin surface.
 *
 *   GET  /release/manifest         install-key auth, unmetered → manifest JSON / 404
 *   GET  /release/download/<ver>   install-key auth, unmetered + own daily limit → tarball
 *   POST /release/publish          admin auth (x-vidi-admin-key) → store tarball + manifest
 */
async function handleRelease(
  request: Request,
  env: Env,
  url: URL
): Promise<Response> {
  if (!env.VIDI_KEYSET) {
    return jsonError(
      "Release storage is not configured (VIDI_KEYSET KV binding missing)",
      503
    );
  }
  // Same physical binding as the keyset; read under the binary-capable interface.
  const releaseKV = env.VIDI_KEYSET as unknown as VidiReleaseKVNamespace;
  const releaseStore = new ReleaseStore(releaseKV);

  try {
    if (request.method === "POST" && url.pathname === "/release/publish") {
      return await handleReleasePublish(request, env, releaseStore);
    }

    if (request.method === "GET" && url.pathname === "/release/manifest") {
      return await handleReleaseManifest(request, env, url, releaseStore);
    }

    if (
      request.method === "GET" &&
      url.pathname.startsWith("/release/download/")
    ) {
      return await handleReleaseDownload(request, env, url, releaseStore);
    }
  } catch (error) {
    console.error(`[${url.pathname}] Release error:`, error);
    return jsonError(String(error), 500);
  }

  return new Response("Method not allowed", { status: 405 });
}

/**
 * GET /release/manifest — the currently-published release metadata. Authed by a
 * valid install key (or the owner key) but NOT metered against the chat quota
 * (it is a cheap reference read, not a proxied upstream call). The `url` field is
 * derived from THIS request's origin so it is correct on any deployed hostname.
 * 404 with `{error}` when nothing has been published yet.
 */
async function handleReleaseManifest(
  request: Request,
  env: Env,
  url: URL,
  releaseStore: ReleaseStore
): Promise<Response> {
  const authorization = await authorizeProxyRequest(request, env, {
    meterUsage: false,
  });
  if (!authorization.ok) {
    return authorization.response;
  }

  const manifest = await releaseStore.getManifest();
  if (!manifest) {
    return jsonError("No release has been published yet", 404);
  }

  return jsonResponse(
    {
      version: manifest.version,
      sha: manifest.sha,
      url: downloadUrlForVersion(url.origin, manifest.version),
      sha256: manifest.sha256,
      notes: manifest.notes,
    },
    200
  );
}

/**
 * GET /release/download/<version> — stream the gzipped tarball for a version.
 * Authed by a valid install key (or the owner key) and NOT metered against the
 * chat quota, but a keyset install carries its OWN modest per-UTC-day download
 * limit so a stuck client cannot drain bandwidth (the owner key is unmetered,
 * matching every other owner route). 404 when the version is unknown.
 */
async function handleReleaseDownload(
  request: Request,
  env: Env,
  url: URL,
  releaseStore: ReleaseStore
): Promise<Response> {
  const authorization = await authorizeProxyRequest(request, env, {
    meterUsage: false,
  });
  if (!authorization.ok) {
    return authorization.response;
  }

  const requestedVersion = decodeURIComponent(
    url.pathname.slice("/release/download/".length)
  );
  if (!isValidReleaseVersion(requestedVersion)) {
    return jsonError("Invalid release version", 400);
  }

  // Per-install download rate limit (keyset installs only; owner is unmetered).
  if (!authorization.auth.isOwner) {
    const rateLimitDecision = await releaseStore.recordDownloadAndCheckLimit(
      authorization.auth.installKeyRecord.keyId,
      new Date(),
      DEFAULT_DAILY_DOWNLOAD_LIMIT
    );
    if (!rateLimitDecision.allowed) {
      return jsonError(
        `Daily download limit exceeded (${rateLimitDecision.dailyDownloadLimit} downloads/day). It resets at UTC midnight.`,
        429
      );
    }
  }

  const tarballBytes = await releaseStore.getTarball(requestedVersion);
  if (!tarballBytes) {
    return jsonError("No release with that version", 404);
  }

  return new Response(tarballBytes, {
    status: 200,
    headers: {
      "content-type": "application/gzip",
      "content-disposition": `attachment; filename="vidi-chat-${requestedVersion}.tar.gz"`,
      "content-length": String(tarballBytes.byteLength),
    },
  });
}

/**
 * POST /release/publish — store a new release. ADMIN auth only (the same
 * `x-vidi-admin-key` credential the keyset admin surface uses). The body is
 * `multipart/form-data` with text fields `version`, `sha`, `notes` and a file
 * field `tarball` (the gzipped `git archive`). The worker computes the sha256
 * from the received bytes itself (authoritative — never trusts a client-sent
 * hash), stamps `publishedAt`, and stores the tarball + manifest in KV.
 */
async function handleReleasePublish(
  request: Request,
  env: Env,
  releaseStore: ReleaseStore
): Promise<Response> {
  const expectedAdminKey = env.VIDI_ADMIN_KEY || env.VIDI_PROXY_KEY;
  const providedAdminKey = request.headers.get("x-vidi-admin-key") || "";
  if (
    !expectedAdminKey ||
    !constantTimeEquals(providedAdminKey, expectedAdminKey)
  ) {
    return jsonError(
      "Unauthorized: missing or invalid x-vidi-admin-key header",
      401
    );
  }

  const incomingContentType = request.headers.get("content-type") || "";
  if (!incomingContentType.includes("multipart/form-data")) {
    return jsonError(
      "Publish expects a multipart/form-data body (fields: version, sha, notes, tarball)",
      400
    );
  }

  let publishForm: FormData;
  try {
    publishForm = await request.formData();
  } catch {
    return jsonError("Invalid multipart/form-data body", 400);
  }

  const version = publishForm.get("version");
  if (!isValidReleaseVersion(version)) {
    return jsonError(
      'Missing or invalid "version" (1-64 chars: letters, digits, . _ -)',
      400
    );
  }
  const sha = publishForm.get("sha");
  if (typeof sha !== "string" || sha.trim().length === 0) {
    return jsonError('Missing required field "sha" (vidi-chat commit)', 400);
  }
  const notesField = publishForm.get("notes");
  const notes = typeof notesField === "string" ? notesField.trim() : "";

  const tarballField = publishForm.get("tarball");
  // A file part surfaces as a Blob/File; a text part is a string. Require a Blob.
  if (!(tarballField instanceof Blob)) {
    return jsonError('Missing required file field "tarball"', 400);
  }
  const tarballBytes = await tarballField.arrayBuffer();
  if (tarballBytes.byteLength === 0) {
    return jsonError('The "tarball" file is empty', 400);
  }

  const sha256 = await sha256HexOfBytes(tarballBytes);
  const manifest: StoredReleaseManifest = {
    version,
    sha: sha.trim(),
    sha256,
    notes,
    publishedAt: new Date().toISOString(),
  };
  await releaseStore.publish(manifest, tarballBytes);

  return jsonResponse(
    {
      published: true,
      version: manifest.version,
      sha: manifest.sha,
      sha256: manifest.sha256,
      bytes: tarballBytes.byteLength,
      publishedAt: manifest.publishedAt,
    },
    201
  );
}

/**
 * POST /admin/keys/update — change an existing key's label, quota, or voice
 * entitlements. The key is identified by `keyId` (preferred) or a unique `label`.
 * Entitlement changes: `allowedVoiceIds` replaces the set, `addAllowedVoiceIds`
 * unions ids in (the "add a clone to an existing key" path), `defaultVoiceId`
 * sets (string) or clears (null) the default. The merged result is validated so a
 * dead or inconsistent entitlement can never be persisted.
 */
async function handleAdminKeysUpdate(
  request: Request,
  keysetStore: KeysetStore
): Promise<Response> {
  let updateRequestBody: Record<string, unknown> = {};
  try {
    updateRequestBody = (await request.json()) as Record<string, unknown>;
  } catch {
    updateRequestBody = {};
  }

  // Resolve the target key by keyId, else by a unique label.
  let targetKeyId: string;
  if (
    typeof updateRequestBody.keyId === "string" &&
    updateRequestBody.keyId.length > 0
  ) {
    targetKeyId = updateRequestBody.keyId;
  } else if (
    typeof updateRequestBody.label === "string" &&
    updateRequestBody.label.length > 0
  ) {
    const labelMatch = await keysetStore.findKeyIdByLabel(updateRequestBody.label);
    if (labelMatch.keyId === null) {
      return jsonError(
        labelMatch.matchCount === 0
          ? `No install key with label ${JSON.stringify(updateRequestBody.label)}`
          : `Label ${JSON.stringify(updateRequestBody.label)} matches ${labelMatch.matchCount} keys — update by keyId instead`,
        labelMatch.matchCount === 0 ? 404 : 409
      );
    }
    targetKeyId = labelMatch.keyId;
  } else {
    return jsonError('Provide "keyId" or a unique "label" to identify the key', 400);
  }

  // Optional quota change reuses the mint-path validation (integer >= 1).
  let dailyQuotaRequestsUpdate: number | undefined;
  if (
    updateRequestBody.dailyQuotaRequests !== undefined &&
    updateRequestBody.dailyQuotaRequests !== null
  ) {
    const value = updateRequestBody.dailyQuotaRequests;
    if (typeof value === "number" && Number.isInteger(value) && value >= 1) {
      dailyQuotaRequestsUpdate = value;
    } else {
      return jsonError(
        'Invalid "dailyQuotaRequests": must be an integer >= 1 when provided',
        400
      );
    }
  }

  const allowedVoiceIdsUpdate = readStringArrayField(
    updateRequestBody.allowedVoiceIds
  );
  if (allowedVoiceIdsUpdate.invalid) {
    return jsonError('Invalid "allowedVoiceIds": must be an array of strings', 400);
  }
  const addAllowedVoiceIdsUpdate = readStringArrayField(
    updateRequestBody.addAllowedVoiceIds
  );
  if (addAllowedVoiceIdsUpdate.invalid) {
    return jsonError(
      'Invalid "addAllowedVoiceIds": must be an array of strings',
      400
    );
  }

  // defaultVoiceId: string to set, explicit null to clear, absent to leave.
  let defaultVoiceIdUpdate: string | null | undefined;
  if (updateRequestBody.defaultVoiceId === null) {
    defaultVoiceIdUpdate = null;
  } else if (typeof updateRequestBody.defaultVoiceId === "string") {
    defaultVoiceIdUpdate = updateRequestBody.defaultVoiceId;
  } else if (updateRequestBody.defaultVoiceId !== undefined) {
    return jsonError(
      'Invalid "defaultVoiceId": must be a string (set) or null (clear)',
      400
    );
  }

  const labelUpdate =
    typeof updateRequestBody.label === "string" &&
    updateRequestBody.label.trim().length > 0 &&
    // Only treat label as a rename when the key was targeted by keyId; a label
    // used to LOCATE the key is not a rename.
    typeof updateRequestBody.keyId === "string"
      ? updateRequestBody.label.trim()
      : undefined;

  // `updateKeyByKeyId` merges + validates the candidate record BEFORE any KV
  // write, so an "invalid" outcome here means nothing was persisted — the
  // previously-stored record is guaranteed byte-unchanged.
  const updateOutcome = await keysetStore.updateKeyByKeyId(targetKeyId, {
    label: labelUpdate,
    dailyQuotaRequests: dailyQuotaRequestsUpdate,
    allowedVoiceIds: allowedVoiceIdsUpdate.values,
    addAllowedVoiceIds: addAllowedVoiceIdsUpdate.values,
    defaultVoiceId: defaultVoiceIdUpdate,
  });
  if (!updateOutcome.ok) {
    if (updateOutcome.reason === "not-found") {
      return jsonError("No install key with that keyId", 404);
    }
    return jsonError(updateOutcome.error, 400);
  }
  const updatedRecord = updateOutcome.record;

  return jsonResponse(
    {
      keyId: updatedRecord.keyId,
      label: updatedRecord.label,
      dailyQuotaRequests: updatedRecord.dailyQuotaRequests,
      allowedVoiceIds: updatedRecord.allowedVoiceIds ?? [],
      defaultVoiceId: updatedRecord.defaultVoiceId ?? null,
    },
    200
  );
}

/**
 * Parse optional `allowedVoiceIds` (string[]) and `defaultVoiceId` (string) from
 * an admin mint body. Returns `{ error }` on a shape mismatch. Content validity
 * (known voice / entitled default) is checked separately by
 * `validateEntitlementSelection`.
 */
function parseVoiceEntitlementFields(
  body: Record<string, unknown>
):
  | { allowedVoiceIds?: string[]; defaultVoiceId?: string }
  | { error: string } {
  const allowedVoiceIds = readStringArrayField(body.allowedVoiceIds);
  if (allowedVoiceIds.invalid) {
    return { error: 'Invalid "allowedVoiceIds": must be an array of strings' };
  }
  let defaultVoiceId: string | undefined;
  if (body.defaultVoiceId !== undefined && body.defaultVoiceId !== null) {
    if (typeof body.defaultVoiceId !== "string") {
      return { error: 'Invalid "defaultVoiceId": must be a string' };
    }
    defaultVoiceId = body.defaultVoiceId;
  }
  return { allowedVoiceIds: allowedVoiceIds.values, defaultVoiceId };
}

/**
 * Read an optional field that must be a string[] when present. Returns
 * `{ invalid: true }` on a type mismatch, else the values (or undefined when the
 * field was absent).
 */
function readStringArrayField(
  fieldValue: unknown
): { invalid: false; values: string[] | undefined } | { invalid: true } {
  if (fieldValue === undefined || fieldValue === null) {
    return { invalid: false, values: undefined };
  }
  if (
    !Array.isArray(fieldValue) ||
    !fieldValue.every((element) => typeof element === "string")
  ) {
    return { invalid: true };
  }
  return { invalid: false, values: fieldValue as string[] };
}

async function handleChat(request: Request, env: Env): Promise<Response> {
  let chatRequestBody: Record<string, unknown>;
  try {
    chatRequestBody = await request.json();
  } catch {
    return jsonError("Invalid JSON body", 400);
  }

  const allowedChatModels = (env.CHAT_MODEL_ALLOWLIST || DEFAULT_CHAT_MODEL_ALLOWLIST)
    .split(",")
    .map((modelName) => modelName.trim())
    .filter((modelName) => modelName.length > 0);

  const requestedModel = chatRequestBody.model;
  if (
    typeof requestedModel !== "string" ||
    !allowedChatModels.includes(requestedModel)
  ) {
    return jsonError(
      `Model "${String(requestedModel)}" is not allowed. Allowed models: ${allowedChatModels.join(", ")}`,
      400
    );
  }

  // Cap the completion-token budget — clamp rather than reject so the app
  // keeps working. OpenAI-compatible APIs accept either `max_tokens` (legacy)
  // or `max_completion_tokens` (current); clamp whichever the client sent.
  const hasMaxTokens = typeof chatRequestBody.max_tokens === "number";
  const hasMaxCompletionTokens = typeof chatRequestBody.max_completion_tokens === "number";
  if (hasMaxTokens && (chatRequestBody.max_tokens as number) > MAX_TOKENS_CAP) {
    chatRequestBody.max_tokens = MAX_TOKENS_CAP;
  }
  if (hasMaxCompletionTokens && (chatRequestBody.max_completion_tokens as number) > MAX_TOKENS_CAP) {
    chatRequestBody.max_completion_tokens = MAX_TOKENS_CAP;
  }
  if (!hasMaxTokens && !hasMaxCompletionTokens) {
    chatRequestBody.max_completion_tokens = DEFAULT_MAX_COMPLETION_TOKENS;
  }

  // Pick the upstream brain: OpenAI by default, Grok when CHAT_PROVIDER is
  // "grok". Both speak the OpenAI chat-completions format, so the request
  // body passes through unchanged either way.
  const chatProvider = env.CHAT_PROVIDER || "openai";
  let upstreamChatURL: string;
  let upstreamChatAPIKey: string | undefined;
  if (chatProvider === "grok") {
    upstreamChatURL = "https://api.x.ai/v1/chat/completions";
    upstreamChatAPIKey = env.XAI_API_KEY;
    if (!upstreamChatAPIKey) {
      return jsonError(
        'Chat is not configured: XAI_API_KEY secret is missing (CHAT_PROVIDER is "grok")',
        503
      );
    }
  } else {
    upstreamChatURL = "https://api.openai.com/v1/chat/completions";
    upstreamChatAPIKey = env.OPENAI_API_KEY;
    if (!upstreamChatAPIKey) {
      return jsonError(
        'Chat is not configured: OPENAI_API_KEY secret is missing (CHAT_PROVIDER is "openai")',
        503
      );
    }
  }

  const response = await fetch(upstreamChatURL, {
    method: "POST",
    headers: {
      authorization: `Bearer ${upstreamChatAPIKey}`,
      "content-type": "application/json",
    },
    body: JSON.stringify(chatRequestBody),
  });

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/chat] ${chatProvider} chat API error ${response.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }

  // Stream the upstream body (SSE) through verbatim — do not buffer.
  return new Response(response.body, {
    status: response.status,
    headers: {
      "content-type": response.headers.get("content-type") || "text/event-stream",
      "cache-control": "no-cache",
    },
  });
}

async function handleTranscribeToken(env: Env): Promise<Response> {
  if (!env.ASSEMBLYAI_API_KEY) {
    return jsonError(
      "Transcription is not configured: ASSEMBLYAI_API_KEY secret is missing",
      503
    );
  }

  const response = await fetch(
    "https://streaming.assemblyai.com/v3/token?expires_in_seconds=480",
    {
      method: "GET",
      headers: {
        authorization: env.ASSEMBLYAI_API_KEY,
      },
    }
  );

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/transcribe-token] AssemblyAI token error ${response.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }

  const data = await response.text();
  return new Response(data, {
    status: 200,
    headers: { "content-type": "application/json" },
  });
}

async function handleTranscribe(request: Request, env: Env): Promise<Response> {
  if (!env.XAI_API_KEY) {
    return jsonError(
      "Transcription is not configured: XAI_API_KEY secret is missing",
      503
    );
  }

  // The app POSTs a multipart/form-data body containing the captured PTT clip
  // (a 16 kHz mono PCM16 WAV in the `file` field) plus xAI's optional fields
  // (`model=grok-stt`, `language=en`, `format=true`). Grok's STT endpoint
  // requires `file` to come AFTER every other field, so the app is responsible
  // for that field ordering — the worker forwards the body VERBATIM (streamed,
  // not re-parsed) and only swaps the client's `x-vidi-key` for the real xAI
  // Bearer key, exactly like the /chat and /tts proxies.
  const incomingContentType = request.headers.get("content-type");
  if (!incomingContentType || !incomingContentType.includes("multipart/form-data")) {
    return jsonError(
      'Transcription expects a multipart/form-data body with a `file` field',
      400
    );
  }

  // Buffer the whole multipart body (a short PTT clip — a few hundred KB, well
  // under the 500 MB xAI cap) rather than streaming `request.body` through.
  // A finite ArrayBuffer forwards deterministically and avoids duplex-stream
  // edge cases in the Workers fetch.
  const multipartBody = await request.arrayBuffer();

  const response = await fetch("https://api.x.ai/v1/stt", {
    method: "POST",
    headers: {
      authorization: `Bearer ${env.XAI_API_KEY}`,
      // Forward the exact multipart content-type (including the boundary) the
      // app generated so the upstream parser reads the same body bytes.
      "content-type": incomingContentType,
    },
    body: multipartBody,
  });

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/transcribe] Grok STT API error ${response.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }

  // Grok returns JSON with the transcript at top-level `text`. Pass it through
  // unchanged so the app reads `body.text`.
  const transcriptJSON = await response.text();
  return new Response(transcriptJSON, {
    status: 200,
    headers: { "content-type": "application/json" },
  });
}

async function handleTranscribeSarvam(request: Request, env: Env): Promise<Response> {
  if (!env.SARVAM_API_KEY) {
    return jsonError(
      "Transcription is not configured: SARVAM_API_KEY secret is missing",
      503
    );
  }

  // The app POSTs a multipart/form-data body containing the captured PTT clip
  // (a 16 kHz mono PCM16 WAV in the `file` field) plus Sarvam's fields
  // (`model=saarika:v2.5`, `language_code=en-IN`). Unlike xAI, Sarvam has no
  // "file must be last" ordering requirement, but the app keeps the same field
  // ordering as the Grok path for symmetry. The worker forwards the body
  // VERBATIM (buffered, not re-parsed) and swaps the client's `x-vidi-key` for
  // the real Sarvam key — which Sarvam takes as `api-subscription-key`, NOT a
  // Bearer token — exactly like the /transcribe (Grok) proxy.
  const incomingContentType = request.headers.get("content-type");
  if (!incomingContentType || !incomingContentType.includes("multipart/form-data")) {
    return jsonError(
      'Transcription expects a multipart/form-data body with a `file` field',
      400
    );
  }

  // Buffer the whole multipart body (a short PTT clip — a few hundred KB) rather
  // than streaming `request.body` through. A finite ArrayBuffer forwards
  // deterministically and avoids duplex-stream edge cases in the Workers fetch.
  const multipartBody = await request.arrayBuffer();

  const response = await fetch("https://api.sarvam.ai/speech-to-text", {
    method: "POST",
    headers: {
      // Sarvam authenticates with a subscription-key header, NOT `Authorization: Bearer`.
      "api-subscription-key": env.SARVAM_API_KEY,
      // Forward the exact multipart content-type (including the boundary) the
      // app generated so the upstream parser reads the same body bytes.
      "content-type": incomingContentType,
    },
    body: multipartBody,
  });

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/transcribe-sarvam] Sarvam STT API error ${response.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }

  // Sarvam returns JSON with the transcript at top-level `transcript`. Pass it
  // through unchanged so the app reads `body.transcript`.
  const transcriptJSON = await response.text();
  return new Response(transcriptJSON, {
    status: 200,
    headers: { "content-type": "application/json" },
  });
}

async function handleTTS(
  request: Request,
  env: Env,
  auth: ProxyAuthContext
): Promise<Response> {
  let ttsRequestBody: Record<string, unknown>;
  try {
    ttsRequestBody = await request.json();
  } catch {
    return jsonError("Invalid JSON body", 400);
  }

  const textToSpeak = ttsRequestBody.text;
  if (typeof textToSpeak !== "string" || textToSpeak.length === 0) {
    return jsonError('Missing required field "text" (non-empty string)', 400);
  }

  // Optional per-request voiceId. Validate the shape before resolving so a
  // non-string never reaches routing or an upstream URL.
  const requestedVoiceIdField = ttsRequestBody.voiceId;
  if (
    requestedVoiceIdField !== undefined &&
    typeof requestedVoiceIdField !== "string"
  ) {
    return jsonError('Invalid "voiceId": must be a string when provided', 400);
  }

  const voiceResolution = resolveVoiceSelection({
    requestedVoiceId: requestedVoiceIdField,
    keyDefaultVoiceId: auth.isOwner
      ? undefined
      : auth.installKeyRecord.defaultVoiceId,
    keyAllowedVoiceIds: auth.isOwner
      ? undefined
      : auth.installKeyRecord.allowedVoiceIds,
    isOwner: auth.isOwner,
    elevenLabsConfigured: Boolean(env.ELEVENLABS_API_KEY),
  });

  if (voiceResolution.kind === "forbidden") {
    return jsonResponse(
      { error: voiceResolution.reason, voiceId: voiceResolution.voiceId },
      403
    );
  }
  if (voiceResolution.kind === "unavailable") {
    return jsonResponse(
      { error: voiceResolution.reason, voiceId: voiceResolution.voiceId },
      503
    );
  }

  // No voiceId in play → the worker's original global TTS behavior, byte-for-byte
  // (TTS_PROVIDER + GROK_VOICE_ID/ELEVENLABS_VOICE_ID vars).
  if (voiceResolution.kind === "global-default") {
    const ttsProvider = env.TTS_PROVIDER || "grok";
    if (ttsProvider === "elevenlabs") {
      return await handleElevenLabsTTS(ttsRequestBody, env, env.ELEVENLABS_VOICE_ID);
    }
    return await handleGrokTTS(textToSpeak, env, env.GROK_VOICE_ID || "ara");
  }

  // A specific, entitled voiceId — route by its family.
  if (voiceResolution.route === "grok") {
    return await handleGrokTTS(textToSpeak, env, voiceResolution.voiceId);
  }
  return await handleElevenLabsTTS(ttsRequestBody, env, voiceResolution.voiceId);
}

/**
 * The voices the authenticated caller may select, for the vidi-chat picker.
 * Cache-friendly (unmetered; short public cache): the owner sees the global Grok
 * stock voices (plus the configured global ElevenLabs voice, if any); a keyset
 * key sees the Grok stock voices plus its own entitled voices, with its default
 * marked.
 */
function handleVoicesCatalog(env: Env, auth: ProxyAuthContext): Response {
  const allowedVoiceIds = auth.isOwner
    ? env.ELEVENLABS_API_KEY && env.ELEVENLABS_VOICE_ID
      ? [env.ELEVENLABS_VOICE_ID]
      : undefined
    : auth.installKeyRecord.allowedVoiceIds;
  const defaultVoiceId = auth.isOwner
    ? undefined
    : auth.installKeyRecord.defaultVoiceId;

  const voices = catalogForKey(allowedVoiceIds, defaultVoiceId);
  return new Response(JSON.stringify({ voices }), {
    status: 200,
    headers: {
      "content-type": "application/json",
      // Reference data changes rarely; let the picker cache it briefly.
      "cache-control": "public, max-age=300",
    },
  });
}

/**
 * POST /feedback — relay user-triggered feedback (or a consented weekly health
 * summary) to the owner's Discord webhook. Order of checks (each short-circuits):
 *
 *   401  handled by the caller (authorizeProxyRequest) before we get here
 *   413  raw body larger than MAX_FEEDBACK_BODY_BYTES
 *   400  invalid JSON / missing text / unknown kind
 *   429  per-key send cap exceeded (keyset installs only; owner is unmetered)
 *   503  VIDI_FEEDBACK_WEBHOOK secret unset — returned WITHOUT any upstream fetch
 *   502  the Discord webhook itself failed
 *   200  posted
 *
 * The install LABEL comes from the authenticated key (owner → a fixed label, a
 * keyset key → its record label) — the client never supplies it, so a caller
 * can't spoof who the feedback is from. The webhook URL is never echoed back.
 */
async function handleFeedback(
  request: Request,
  env: Env,
  auth: ProxyAuthContext
): Promise<Response> {
  // Size cap on the RAW body first, before parsing, so an oversized payload is
  // rejected cheaply and never buffered into JSON.
  const rawBody = await request.text();
  if (new TextEncoder().encode(rawBody).length > MAX_FEEDBACK_BODY_BYTES) {
    return jsonError(
      `Feedback body too large (max ${MAX_FEEDBACK_BODY_BYTES} bytes)`,
      413
    );
  }

  let feedbackRequestBody: Record<string, unknown>;
  try {
    feedbackRequestBody = JSON.parse(rawBody || "{}") as Record<string, unknown>;
  } catch {
    return jsonError("Invalid JSON body", 400);
  }

  const feedbackText = feedbackRequestBody.text;
  if (typeof feedbackText !== "string" || feedbackText.trim().length === 0) {
    return jsonError('Missing required field "text" (non-empty string)', 400);
  }

  const kind: FeedbackKind = isFeedbackKind(feedbackRequestBody.kind)
    ? feedbackRequestBody.kind
    : "feedback";

  const reportField = feedbackRequestBody.report;
  const report =
    typeof reportField === "string" && reportField.trim().length > 0
      ? reportField
      : null;

  // Per-key send cap — keyset installs only (the owner key is unmetered, matching
  // every other owner route). Ordinary feedback: FEEDBACK_DAILY_CAP per UTC day;
  // the weekly summary: WEEKLY_SUMMARY_WEEKLY_CAP per UTC week.
  let installLabel = "owner";
  if (!auth.isOwner) {
    installLabel = auth.installKeyRecord.label;
    if (env.VIDI_KEYSET) {
      const keysetStore = new KeysetStore(env.VIDI_KEYSET);
      const now = new Date();
      const capDecision =
        kind === "weekly-summary"
          ? await keysetStore.recordFeedbackAndCheckCap(
              auth.installKeyRecord.keyId,
              `wk:${weekStamp(now)}`,
              WEEKLY_SUMMARY_WEEKLY_CAP
            )
          : await keysetStore.recordFeedbackAndCheckCap(
              auth.installKeyRecord.keyId,
              `day:${feedbackDateStamp(now)}`,
              FEEDBACK_DAILY_CAP
            );
      if (!capDecision.allowed) {
        return jsonError(
          kind === "weekly-summary"
            ? `Weekly summary already sent this week (max ${WEEKLY_SUMMARY_WEEKLY_CAP}).`
            : `Feedback send limit reached (${FEEDBACK_DAILY_CAP}/day). It resets at UTC midnight.`,
          429
        );
      }
    }
  }

  // Secret must be present BEFORE any upstream call — a missing webhook 503s
  // with zero outbound fetch.
  if (!env.VIDI_FEEDBACK_WEBHOOK) {
    return jsonError("Feedback is not configured (VIDI_FEEDBACK_WEBHOOK unset)", 503);
  }

  const content = buildFeedbackDiscordContent(kind, installLabel, feedbackText, report);
  let webhookResponse: Response;
  try {
    webhookResponse = await fetch(env.VIDI_FEEDBACK_WEBHOOK, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ content }),
    });
  } catch (error) {
    console.error("[/feedback] webhook fetch failed:", error);
    return jsonError("Feedback delivery failed", 502);
  }

  if (!webhookResponse.ok) {
    // Never echo the webhook URL or its response body (may include it).
    console.error(`[/feedback] webhook returned ${webhookResponse.status}`);
    return jsonError("Feedback delivery failed", 502);
  }

  return jsonResponse({ delivered: true }, 200);
}

async function handleGrokTTS(
  textToSpeak: string,
  env: Env,
  grokVoiceId: string
): Promise<Response> {
  if (!env.XAI_API_KEY) {
    return jsonError(
      "TTS is not configured: XAI_API_KEY secret is missing (TTS_PROVIDER is \"grok\")",
      503
    );
  }

  const response = await fetch("https://api.x.ai/v1/tts", {
    method: "POST",
    headers: {
      authorization: `Bearer ${env.XAI_API_KEY}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({
      text: textToSpeak,
      voice_id: grokVoiceId,
      language: "en",
    }),
  });

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/tts] Grok TTS API error ${response.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }

  return new Response(response.body, {
    status: response.status,
    headers: {
      "content-type": response.headers.get("content-type") || "audio/mpeg",
    },
  });
}

async function handleElevenLabsTTS(
  ttsRequestBody: Record<string, unknown>,
  env: Env,
  elevenLabsVoiceId: string | undefined
): Promise<Response> {
  if (!env.ELEVENLABS_API_KEY) {
    return jsonError(
      "TTS is not configured: ELEVENLABS_API_KEY secret is missing (TTS_PROVIDER is \"elevenlabs\")",
      503
    );
  }

  // Only ever an entitled/resolved id (or the configured global var) reaches this
  // point — an arbitrary caller-supplied id is never forwarded into the URL.
  if (!elevenLabsVoiceId) {
    return jsonError(
      "TTS is not configured: ELEVENLABS_VOICE_ID var is missing (TTS_PROVIDER is \"elevenlabs\")",
      503
    );
  }

  // Forward the parsed body as-is so extra fields the app sends
  // (model_id, voice_settings, ...) reach ElevenLabs unchanged.
  const response = await fetch(
    `https://api.elevenlabs.io/v1/text-to-speech/${elevenLabsVoiceId}`,
    {
      method: "POST",
      headers: {
        "xi-api-key": env.ELEVENLABS_API_KEY,
        "content-type": "application/json",
        accept: "audio/mpeg",
      },
      body: JSON.stringify(ttsRequestBody),
    }
  );

  if (!response.ok) {
    const errorBody = await response.text();
    console.error(`[/tts] ElevenLabs API error ${response.status}: ${errorBody}`);
    return new Response(errorBody, {
      status: response.status,
      headers: { "content-type": "application/json" },
    });
  }

  return new Response(response.body, {
    status: response.status,
    headers: {
      "content-type": response.headers.get("content-type") || "audio/mpeg",
    },
  });
}
