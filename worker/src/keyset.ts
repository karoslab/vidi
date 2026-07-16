/**
 * Vidi Proxy Worker — per-install keyset (A2).
 *
 * Backwards-compatible multi-user authentication for vidi-proxy. The owner's
 * single shared `VIDI_PROXY_KEY` keeps working unchanged and unmetered (that is
 * the key compiled into the owner's LIVE Mac app). This module adds, ALONGSIDE
 * it, per-install keys that each carry a daily request quota and usage counter,
 * so a second native user can be issued their own revocable, rate-limited key
 * instead of sharing the owner's key and API budget.
 *
 * Storage: Cloudflare Workers KV (binding `VIDI_KEYSET`). Records are keyed by
 * the SHA-256 hash of the raw key — the raw key is never stored, so a KV dump
 * does not leak usable credentials. A separate `id:` index maps the short,
 * non-secret keyId (used by admin revoke/list and by usage counters) to the key
 * hash. Usage counters are per-key, per-UTC-day, with a 2-day TTL.
 *
 * Pure helpers here (hashing, key generation, quota decision, key naming,
 * constant-time compare) are unit-tested directly; the KV-backed `KeysetStore`
 * is exercised end-to-end via an in-memory KV stub in the worker test.
 */

import { validateEntitlementSelection } from "./voices";

export const INSTALL_KEY_PREFIX = "vidi_live_";

// Default per-install daily request quota. Chosen as a cost-cap ceiling well
// above family-level use (audits estimate heavy native use at ~50 turns/day,
// each turn a few worker requests) and low enough to bound a runaway loop.
export const DEFAULT_DAILY_QUOTA_REQUESTS = 500;

// Usage counters live for 2 days so "today" (UTC) is always readable and stale
// day-counters self-expire without a sweep.
export const USAGE_COUNTER_TTL_SECONDS = 60 * 60 * 48;

/**
 * The minimal subset of the Cloudflare KVNamespace API this module uses. Kept
 * as a local interface (rather than depending on @cloudflare/workers-types) so
 * the in-memory test stub can implement exactly this and no new dependency is
 * added to the worker.
 */
export interface VidiKeysetKVNamespace {
  get(key: string): Promise<string | null>;
  put(
    key: string,
    value: string,
    options?: { expirationTtl?: number }
  ): Promise<void>;
  delete(key: string): Promise<void>;
  list(options?: { prefix?: string }): Promise<{ keys: { name: string }[] }>;
}

/** Metadata stored per install key (never contains the raw key). */
export interface InstallKeyRecord {
  keyId: string;
  label: string;
  createdAt: string; // ISO 8601
  revoked: boolean;
  dailyQuotaRequests: number;
  keyPrefix: string; // first chars of the raw key, for admin display only
  // Per-voice entitlements. Both optional so records written before voice
  // entitlements existed parse unchanged (undefined → no extra voices, global
  // Grok stock only). `allowedVoiceIds` are the non-global voices this key may
  // select (e.g. ElevenLabs clones); `defaultVoiceId` is used when a TTS request
  // sends no explicit voiceId.
  allowedVoiceIds?: string[];
  defaultVoiceId?: string;
}

/** Optional per-voice entitlements supplied when minting a key. */
export interface VoiceEntitlements {
  allowedVoiceIds?: string[];
  defaultVoiceId?: string;
}

/** Fields an admin update may change on an existing key (all optional). */
export interface InstallKeyUpdate {
  label?: string;
  dailyQuotaRequests?: number;
  // Replace the entitled-voice set outright.
  allowedVoiceIds?: string[];
  // Union extra ids into the existing entitled-voice set (the "add a clone" path).
  addAllowedVoiceIds?: string[];
  // Set (string) or clear (null) the key's default voice.
  defaultVoiceId?: string | null;
}

/**
 * Result of `KeysetStore.updateKeyByKeyId`. `ok: false, reason: "invalid"`
 * means the merged entitlement selection failed validation — nothing was
 * written to KV, so the previously-stored record is unchanged.
 */
export type UpdateKeyOutcome =
  | { ok: true; record: InstallKeyRecord }
  | { ok: false; reason: "not-found" }
  | { ok: false; reason: "invalid"; error: string };

export interface QuotaDecision {
  allowed: boolean;
  usedRequestsAfterThisOne: number;
  dailyQuotaRequests: number;
}

/**
 * Decide whether one more request is within the daily quota, given how many
 * requests have already been recorded for the key today. Pure — no storage.
 */
export function decideQuota(
  requestsAlreadyUsedToday: number,
  dailyQuotaRequests: number
): QuotaDecision {
  const usedRequestsAfterThisOne = requestsAlreadyUsedToday + 1;
  return {
    allowed: usedRequestsAfterThisOne <= dailyQuotaRequests,
    usedRequestsAfterThisOne,
    dailyQuotaRequests,
  };
}

/** SHA-256 hex of the input, via Web Crypto (Workers + Node 18+). */
export async function sha256Hex(input: string): Promise<string> {
  const inputBytes = new TextEncoder().encode(input);
  const digestBuffer = await crypto.subtle.digest("SHA-256", inputBytes);
  return [...new Uint8Array(digestBuffer)]
    .map((byteValue) => byteValue.toString(16).padStart(2, "0"))
    .join("");
}

/** De-duplicate a string array preserving first-seen order. */
export function dedupeStrings(values: ReadonlyArray<string>): string[] {
  const seen = new Set<string>();
  const result: string[] = [];
  for (const value of values) {
    if (!seen.has(value)) {
      seen.add(value);
      result.push(value);
    }
  }
  return result;
}

/** A random lowercase-hex token of `byteLength` bytes of entropy. */
export function generateRandomHexToken(byteLength: number): string {
  const randomBytes = new Uint8Array(byteLength);
  crypto.getRandomValues(randomBytes);
  return [...randomBytes]
    .map((byteValue) => byteValue.toString(16).padStart(2, "0"))
    .join("");
}

/** A freshly minted raw install key (the only time the raw value exists). */
export function newRawInstallKey(): string {
  return INSTALL_KEY_PREFIX + generateRandomHexToken(24);
}

/** A short, non-secret key identifier used for revoke/list and usage keys. */
export function newKeyId(): string {
  return generateRandomHexToken(8);
}

/** `yyyy-mm-dd` in UTC — the bucket a usage counter lives in. */
export function utcDateStamp(now: Date): string {
  return now.toISOString().slice(0, 10);
}

export function keyRecordKvName(keyHash: string): string {
  return `key:${keyHash}`;
}

export function keyIdIndexKvName(keyId: string): string {
  return `id:${keyId}`;
}

export function usageCounterKvName(keyId: string, dateStamp: string): string {
  return `usage:${keyId}:${dateStamp}`;
}

/** Counter name for the per-install FEEDBACK send cap (its own bucket, distinct
 *  from the chat `usage:` quota). `bucket` is a day stamp for ordinary feedback
 *  or a week stamp for the weekly summary, so the two caps never share a count. */
export function feedbackCounterKvName(keyId: string, bucket: string): string {
  return `feedback:${keyId}:${bucket}`;
}

/**
 * Length-independent constant-time string comparison. Avoids leaking, via
 * response timing, how many leading characters of a guessed key were correct.
 */
export function constantTimeEquals(
  providedValue: string,
  expectedValue: string
): boolean {
  const providedBytes = new TextEncoder().encode(providedValue);
  const expectedBytes = new TextEncoder().encode(expectedValue);
  // Fold the length difference into the accumulator so mismatched lengths still
  // run the full compare loop and cannot short-circuit.
  let differenceAccumulator = providedBytes.length ^ expectedBytes.length;
  const comparisonLength = Math.max(providedBytes.length, expectedBytes.length);
  for (let index = 0; index < comparisonLength; index++) {
    const providedByte = providedBytes[index] ?? 0;
    const expectedByte = expectedBytes[index] ?? 0;
    differenceAccumulator |= providedByte ^ expectedByte;
  }
  return differenceAccumulator === 0;
}

/**
 * KV-backed keyset operations. Thin wrapper over the KV binding — all decision
 * logic it relies on lives in the pure helpers above so it is testable with an
 * in-memory KV stub.
 */
export class KeysetStore {
  constructor(private readonly keysetKV: VidiKeysetKVNamespace) {}

  async issueInstallKey(
    label: string,
    dailyQuotaRequests: number,
    voiceEntitlements?: VoiceEntitlements
  ): Promise<{ rawKey: string; record: InstallKeyRecord }> {
    const rawKey = newRawInstallKey();
    const keyHash = await sha256Hex(rawKey);
    const record: InstallKeyRecord = {
      keyId: newKeyId(),
      label,
      createdAt: new Date().toISOString(),
      revoked: false,
      dailyQuotaRequests,
      keyPrefix: rawKey.slice(0, INSTALL_KEY_PREFIX.length + 6),
    };
    // Only persist the entitlement fields when supplied so keys minted without
    // them stay shaped exactly like pre-entitlement records.
    if (voiceEntitlements?.allowedVoiceIds && voiceEntitlements.allowedVoiceIds.length > 0) {
      record.allowedVoiceIds = dedupeStrings(voiceEntitlements.allowedVoiceIds);
    }
    if (voiceEntitlements?.defaultVoiceId) {
      record.defaultVoiceId = voiceEntitlements.defaultVoiceId;
    }
    await this.keysetKV.put(keyRecordKvName(keyHash), JSON.stringify(record));
    await this.keysetKV.put(keyIdIndexKvName(record.keyId), keyHash);
    return { rawKey, record };
  }

  /** Look up the stored key hash for a keyId, or null if unknown. */
  private async keyHashForKeyId(keyId: string): Promise<string | null> {
    return this.keysetKV.get(keyIdIndexKvName(keyId));
  }

  /**
   * Apply an entitlement/label/quota update to an existing key, identified by
   * keyId. The merged record is computed ENTIRELY IN MEMORY and validated
   * (`validateEntitlementSelection`) BEFORE any KV write — a validation
   * failure must never touch storage, so the stored record stays byte-
   * unchanged and a 400 can never (a) silently grant an unentitled default via
   * a persisted-then-rejected write, or (b) discard a valid `allowedVoiceIds`
   * set to a garbage replacement that fails validation.
   */
  async updateKeyByKeyId(
    keyId: string,
    update: InstallKeyUpdate
  ): Promise<UpdateKeyOutcome> {
    const keyHash = await this.keyHashForKeyId(keyId);
    if (!keyHash) {
      return { ok: false, reason: "not-found" };
    }
    const storedRecord = await this.keysetKV.get(keyRecordKvName(keyHash));
    if (!storedRecord) {
      return { ok: false, reason: "not-found" };
    }
    const existingRecord = JSON.parse(storedRecord) as InstallKeyRecord;

    // Build the candidate merged record without mutating `existingRecord` and
    // WITHOUT any KV write yet.
    const mergedRecord: InstallKeyRecord = { ...existingRecord };

    if (update.label !== undefined) {
      mergedRecord.label = update.label;
    }
    if (update.dailyQuotaRequests !== undefined) {
      mergedRecord.dailyQuotaRequests = update.dailyQuotaRequests;
    }

    // Voice entitlements: `allowedVoiceIds` replaces the set; `addAllowedVoiceIds`
    // unions extra ids in (the "add a clone to an existing key" path).
    let mergedAllowedVoiceIds = update.allowedVoiceIds
      ? [...update.allowedVoiceIds]
      : existingRecord.allowedVoiceIds
        ? [...existingRecord.allowedVoiceIds]
        : [];
    if (update.addAllowedVoiceIds) {
      mergedAllowedVoiceIds = mergedAllowedVoiceIds.concat(update.addAllowedVoiceIds);
    }
    if (update.allowedVoiceIds !== undefined || update.addAllowedVoiceIds !== undefined) {
      const deduped = dedupeStrings(mergedAllowedVoiceIds);
      if (deduped.length > 0) {
        mergedRecord.allowedVoiceIds = deduped;
      } else {
        delete mergedRecord.allowedVoiceIds;
      }
    }

    if (update.defaultVoiceId === null) {
      delete mergedRecord.defaultVoiceId;
    } else if (update.defaultVoiceId !== undefined) {
      mergedRecord.defaultVoiceId = update.defaultVoiceId;
    }

    // Validate the MERGED candidate before it ever reaches KV. On failure,
    // return without writing anything — `existingRecord` in storage is
    // untouched (no partial write, no silently-persisted-then-rejected grant).
    const validationError = validateEntitlementSelection(
      mergedRecord.allowedVoiceIds,
      mergedRecord.defaultVoiceId
    );
    if (validationError) {
      return { ok: false, reason: "invalid", error: validationError };
    }

    await this.keysetKV.put(keyRecordKvName(keyHash), JSON.stringify(mergedRecord));
    return { ok: true, record: mergedRecord };
  }

  /**
   * Resolve a label to the keyId of the single matching key. Returns
   * `{ keyId }` on exactly one match, otherwise an ambiguity/absence marker so
   * the admin surface can return a precise error.
   */
  async findKeyIdByLabel(
    label: string
  ): Promise<{ keyId: string } | { keyId: null; matchCount: number }> {
    const indexEntries = await this.keysetKV.list({ prefix: "id:" });
    const matchingKeyIds: string[] = [];
    for (const indexEntry of indexEntries.keys) {
      const keyHash = await this.keysetKV.get(indexEntry.name);
      if (!keyHash) {
        continue;
      }
      const storedRecord = await this.keysetKV.get(keyRecordKvName(keyHash));
      if (!storedRecord) {
        continue;
      }
      const record = JSON.parse(storedRecord) as InstallKeyRecord;
      if (record.label === label) {
        matchingKeyIds.push(record.keyId);
      }
    }
    if (matchingKeyIds.length === 1) {
      return { keyId: matchingKeyIds[0] };
    }
    return { keyId: null, matchCount: matchingKeyIds.length };
  }

  async lookupByRawKey(rawKey: string): Promise<InstallKeyRecord | null> {
    const keyHash = await sha256Hex(rawKey);
    const storedRecord = await this.keysetKV.get(keyRecordKvName(keyHash));
    return storedRecord ? (JSON.parse(storedRecord) as InstallKeyRecord) : null;
  }

  async revokeByKeyId(keyId: string): Promise<boolean> {
    const keyHash = await this.keysetKV.get(keyIdIndexKvName(keyId));
    if (!keyHash) {
      return false;
    }
    const storedRecord = await this.keysetKV.get(keyRecordKvName(keyHash));
    if (!storedRecord) {
      return false;
    }
    const record = JSON.parse(storedRecord) as InstallKeyRecord;
    record.revoked = true;
    await this.keysetKV.put(keyRecordKvName(keyHash), JSON.stringify(record));
    return true;
  }

  async listKeys(
    now: Date
  ): Promise<Array<InstallKeyRecord & { usedRequestsToday: number }>> {
    const dateStamp = utcDateStamp(now);
    const indexEntries = await this.keysetKV.list({ prefix: "id:" });
    const keysWithUsage: Array<
      InstallKeyRecord & { usedRequestsToday: number }
    > = [];
    for (const indexEntry of indexEntries.keys) {
      const keyHash = await this.keysetKV.get(indexEntry.name);
      if (!keyHash) {
        continue;
      }
      const storedRecord = await this.keysetKV.get(keyRecordKvName(keyHash));
      if (!storedRecord) {
        continue;
      }
      const record = JSON.parse(storedRecord) as InstallKeyRecord;
      const usedRequestsToday = parseInt(
        (await this.keysetKV.get(usageCounterKvName(record.keyId, dateStamp))) ||
          "0",
        10
      );
      keysWithUsage.push({ ...record, usedRequestsToday });
    }
    return keysWithUsage;
  }

  /**
   * Record one request against a key's daily quota. Only increments the counter
   * when the request is within quota, so the stored counter caps at the quota.
   * Read-modify-write on KV is not atomic; a brief concurrency overshoot is
   * acceptable for a per-user cost cap and is documented in the PR.
   */
  async recordUsageAndCheckQuota(
    record: InstallKeyRecord,
    now: Date
  ): Promise<QuotaDecision> {
    const counterName = usageCounterKvName(record.keyId, utcDateStamp(now));
    const requestsAlreadyUsedToday = parseInt(
      (await this.keysetKV.get(counterName)) || "0",
      10
    );
    const decision = decideQuota(
      requestsAlreadyUsedToday,
      record.dailyQuotaRequests
    );
    if (decision.allowed) {
      await this.keysetKV.put(
        counterName,
        String(decision.usedRequestsAfterThisOne),
        { expirationTtl: USAGE_COUNTER_TTL_SECONDS }
      );
    }
    return decision;
  }

  /**
   * Record one FEEDBACK send against a per-install cap that is SEPARATE from the
   * chat quota (its own `feedback:` counter). `bucket` is a day stamp (ordinary
   * feedback) or a week stamp (weekly summary); `cap` is the matching ceiling.
   * Same read-modify-write-if-allowed shape as the chat quota, so the stored
   * counter never exceeds the cap. The counter's TTL keeps a week-bucket alive
   * long enough for the weekly cap to hold (8 days).
   */
  async recordFeedbackAndCheckCap(
    keyId: string,
    bucket: string,
    cap: number
  ): Promise<QuotaDecision> {
    const counterName = feedbackCounterKvName(keyId, bucket);
    const alreadyUsed = parseInt(
      (await this.keysetKV.get(counterName)) || "0",
      10
    );
    const decision = decideQuota(alreadyUsed, cap);
    if (decision.allowed) {
      await this.keysetKV.put(counterName, String(decision.usedRequestsAfterThisOne), {
        // 8 days — long enough for a week bucket to enforce across the week.
        expirationTtl: 60 * 60 * 24 * 8,
      });
    }
    return decision;
  }
}
