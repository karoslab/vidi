import { describe, it, expect } from "vitest";
import {
  INSTALL_KEY_PREFIX,
  DEFAULT_DAILY_QUOTA_REQUESTS,
  KeysetStore,
  constantTimeEquals,
  decideQuota,
  generateRandomHexToken,
  keyIdIndexKvName,
  keyRecordKvName,
  newRawInstallKey,
  sha256Hex,
  usageCounterKvName,
  utcDateStamp,
  type VidiKeysetKVNamespace,
} from "../src/keyset";

/** Minimal in-memory KV that satisfies the subset the keyset uses. */
class InMemoryKV implements VidiKeysetKVNamespace {
  store = new Map<string, string>();
  async get(key: string): Promise<string | null> {
    return this.store.has(key) ? (this.store.get(key) as string) : null;
  }
  async put(key: string, value: string): Promise<void> {
    this.store.set(key, value);
  }
  async delete(key: string): Promise<void> {
    this.store.delete(key);
  }
  async list(options?: { prefix?: string }): Promise<{ keys: { name: string }[] }> {
    const prefix = options?.prefix ?? "";
    return {
      keys: [...this.store.keys()]
        .filter((name) => name.startsWith(prefix))
        .map((name) => ({ name })),
    };
  }
}

describe("decideQuota", () => {
  it("allows requests up to and including the quota, then denies", () => {
    expect(decideQuota(0, 3)).toEqual({
      allowed: true,
      usedRequestsAfterThisOne: 1,
      dailyQuotaRequests: 3,
    });
    expect(decideQuota(2, 3).allowed).toBe(true); // the 3rd request
    expect(decideQuota(3, 3).allowed).toBe(false); // the 4th is over
  });
});

describe("constantTimeEquals", () => {
  it("matches identical strings and rejects differences and length mismatches", () => {
    expect(constantTimeEquals("vidi_live_abc", "vidi_live_abc")).toBe(true);
    expect(constantTimeEquals("vidi_live_abc", "vidi_live_abd")).toBe(false);
    expect(constantTimeEquals("short", "shorter")).toBe(false);
    expect(constantTimeEquals("", "")).toBe(true);
  });
});

describe("key + usage naming", () => {
  it("namespaces records, id index, and usage counters distinctly", () => {
    expect(keyRecordKvName("hash")).toBe("key:hash");
    expect(keyIdIndexKvName("id1")).toBe("id:id1");
    expect(usageCounterKvName("id1", "2026-07-10")).toBe("usage:id1:2026-07-10");
  });
  it("utcDateStamp is the UTC yyyy-mm-dd bucket", () => {
    expect(utcDateStamp(new Date("2026-07-10T23:59:00Z"))).toBe("2026-07-10");
  });
});

describe("key generation", () => {
  it("raw install keys carry the prefix and are unique", () => {
    const first = newRawInstallKey();
    const second = newRawInstallKey();
    expect(first.startsWith(INSTALL_KEY_PREFIX)).toBe(true);
    expect(first).not.toEqual(second);
  });
  it("sha256Hex is stable and hex", async () => {
    const hash = await sha256Hex("vidi_live_test");
    expect(hash).toMatch(/^[0-9a-f]{64}$/);
    expect(await sha256Hex("vidi_live_test")).toEqual(hash);
  });
  it("does not store the raw key anywhere in the record entry", async () => {
    const kv = new InMemoryKV();
    const store = new KeysetStore(kv);
    const { rawKey } = await store.issueInstallKey("test", 10);
    for (const storedValue of kv.store.values()) {
      expect(storedValue).not.toContain(rawKey);
    }
  });
});

describe("KeysetStore end to end (in-memory KV)", () => {
  it("issues, looks up, meters, and enforces the daily quota", async () => {
    const kv = new InMemoryKV();
    const store = new KeysetStore(kv);
    const now = new Date("2026-07-10T12:00:00Z");

    const { rawKey, record } = await store.issueInstallKey("test-mac", 2);
    expect(record.dailyQuotaRequests).toBe(2);

    const found = await store.lookupByRawKey(rawKey);
    expect(found?.keyId).toBe(record.keyId);

    const first = await store.recordUsageAndCheckQuota(record, now);
    const second = await store.recordUsageAndCheckQuota(record, now);
    const third = await store.recordUsageAndCheckQuota(record, now);
    expect(first.allowed).toBe(true);
    expect(second.allowed).toBe(true);
    expect(third.allowed).toBe(false); // over the quota of 2

    // The counter caps at the quota (the denied request is not counted).
    const usage = await kv.get(usageCounterKvName(record.keyId, "2026-07-10"));
    expect(usage).toBe("2");
  });

  it("resets the quota on a new UTC day", async () => {
    const kv = new InMemoryKV();
    const store = new KeysetStore(kv);
    const { record } = await store.issueInstallKey("test-mac", 1);
    const dayOne = new Date("2026-07-10T12:00:00Z");
    const dayTwo = new Date("2026-07-11T12:00:00Z");
    expect((await store.recordUsageAndCheckQuota(record, dayOne)).allowed).toBe(true);
    expect((await store.recordUsageAndCheckQuota(record, dayOne)).allowed).toBe(false);
    expect((await store.recordUsageAndCheckQuota(record, dayTwo)).allowed).toBe(true);
  });

  it("revokes by keyId and blocks subsequent lookups from authorizing", async () => {
    const kv = new InMemoryKV();
    const store = new KeysetStore(kv);
    const { rawKey, record } = await store.issueInstallKey("stranger", 100);
    expect(await store.revokeByKeyId(record.keyId)).toBe(true);
    const found = await store.lookupByRawKey(rawKey);
    expect(found?.revoked).toBe(true);
    expect(await store.revokeByKeyId("nonexistent")).toBe(false);
  });

  it("lists issued keys with today's usage and no raw secret", async () => {
    const kv = new InMemoryKV();
    const store = new KeysetStore(kv);
    const now = new Date("2026-07-10T12:00:00Z");
    const { record } = await store.issueInstallKey("test-mac", 50);
    await store.recordUsageAndCheckQuota(record, now);
    const listed = await store.listKeys(now);
    expect(listed).toHaveLength(1);
    expect(listed[0].keyId).toBe(record.keyId);
    expect(listed[0].usedRequestsToday).toBe(1);
    expect(JSON.stringify(listed[0])).not.toContain(INSTALL_KEY_PREFIX + "0");
  });
});

describe("defaults", () => {
  it("exposes a sane default daily quota", () => {
    expect(DEFAULT_DAILY_QUOTA_REQUESTS).toBeGreaterThan(0);
    expect(generateRandomHexToken(4)).toMatch(/^[0-9a-f]{8}$/);
  });
});
