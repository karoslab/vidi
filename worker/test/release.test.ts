import { describe, it, expect } from "vitest";
import worker from "../src/index";
import {
  decideDownloadRateLimit,
  downloadUrlForVersion,
  isValidReleaseVersion,
  sha256HexOfBytes,
  tarballKvName,
  MANIFEST_KV_NAME,
  DEFAULT_DAILY_DOWNLOAD_LIMIT,
  type VidiReleaseKVNamespace,
} from "../src/release";

/**
 * Binary-capable in-memory KV standing in for the VIDI_KEYSET binding. The
 * production keyset stores strings; the release channel stores an ArrayBuffer
 * tarball in the same namespace, so this stub handles both value types and the
 * `get(key, "arrayBuffer")` overload the ReleaseStore uses.
 */
class BinaryInMemoryKV implements VidiReleaseKVNamespace {
  store = new Map<string, string | ArrayBuffer>();
  async get(key: string): Promise<string | null>;
  async get(key: string, type: "arrayBuffer"): Promise<ArrayBuffer | null>;
  async get(
    key: string,
    type?: "arrayBuffer"
  ): Promise<string | ArrayBuffer | null> {
    if (!this.store.has(key)) {
      return null;
    }
    const value = this.store.get(key) as string | ArrayBuffer;
    if (type === "arrayBuffer") {
      return value instanceof ArrayBuffer
        ? value
        : new TextEncoder().encode(value as string).buffer;
    }
    return value instanceof ArrayBuffer ? null : (value as string);
  }
  async put(key: string, value: string | ArrayBuffer): Promise<void> {
    this.store.set(key, value);
  }
  async delete(key: string): Promise<void> {
    this.store.delete(key);
  }
  async list(): Promise<{ keys: { name: string }[] }> {
    return { keys: [...this.store.keys()].map((name) => ({ name })) };
  }
}

const OWNER_KEY = "owner-shared-key-abc123";
const ADMIN_HEADER = { "x-vidi-admin-key": OWNER_KEY };

type TestEnv = Record<string, unknown>;

/** Copy bytes into a freshly-allocated ArrayBuffer (satisfies Blob/crypto typing). */
function toArrayBuffer(bytes: Uint8Array): ArrayBuffer {
  const copy = new ArrayBuffer(bytes.byteLength);
  new Uint8Array(copy).set(bytes);
  return copy;
}

function envWithKeyset(): TestEnv {
  return { VIDI_PROXY_KEY: OWNER_KEY, VIDI_KEYSET: new BinaryInMemoryKV() };
}

async function callWorker(request: Request, env: TestEnv): Promise<Response> {
  return worker.fetch(request as never, env as never);
}

function releaseUrl(path: string): string {
  return `https://vidi-proxy.example.dev${path}`;
}

/** Build a multipart publish request from fields + tarball bytes. */
function publishRequest(
  fields: { version?: string; sha?: string; notes?: string },
  tarballBytes: Uint8Array | null,
  headers: Record<string, string> = ADMIN_HEADER
): Request {
  const form = new FormData();
  if (fields.version !== undefined) form.set("version", fields.version);
  if (fields.sha !== undefined) form.set("sha", fields.sha);
  if (fields.notes !== undefined) form.set("notes", fields.notes);
  if (tarballBytes !== null) {
    form.set(
      "tarball",
      new Blob([toArrayBuffer(tarballBytes)], { type: "application/gzip" }),
      "vidi-chat.tar.gz"
    );
  }
  return new Request(releaseUrl("/release/publish"), {
    method: "POST",
    headers,
    body: form,
  });
}

/** Mint a real per-install key through the admin surface (returns the raw key). */
async function mintInstallKey(env: TestEnv): Promise<string> {
  const response = await callWorker(
    new Request(releaseUrl("/admin/keys"), {
      method: "POST",
      headers: { ...ADMIN_HEADER, "content-type": "application/json" },
      body: JSON.stringify({ label: "test-install", dailyQuotaRequests: 5 }),
    }),
    env
  );
  return (await response.json()).key;
}

const SAMPLE_TARBALL = new Uint8Array([0x1f, 0x8b, 0x08, 0x00, 1, 2, 3, 4, 5]);

describe("release pure helpers", () => {
  it("validates version strings safe for a KV key + URL segment", () => {
    expect(isValidReleaseVersion("1.2.3")).toBe(true);
    expect(isValidReleaseVersion("2026-07-12_abcdef0")).toBe(true);
    expect(isValidReleaseVersion("v1")).toBe(true);
    expect(isValidReleaseVersion("")).toBe(false);
    expect(isValidReleaseVersion("has space")).toBe(false);
    expect(isValidReleaseVersion("path/traversal")).toBe(false);
    expect(isValidReleaseVersion("release:manifest")).toBe(false);
    expect(isValidReleaseVersion(123)).toBe(false);
    expect(isValidReleaseVersion("x".repeat(65))).toBe(false);
  });

  it("derives the absolute download url from the request origin", () => {
    expect(
      downloadUrlForVersion("https://vidi-proxy.example.dev", "1.2.3")
    ).toBe("https://vidi-proxy.example.dev/release/download/1.2.3");
  });

  it("computes a stable sha256 of the tarball bytes", async () => {
    const hash = await sha256HexOfBytes(toArrayBuffer(SAMPLE_TARBALL));
    expect(hash).toMatch(/^[0-9a-f]{64}$/);
    // Deterministic for the same bytes.
    expect(await sha256HexOfBytes(toArrayBuffer(SAMPLE_TARBALL))).toBe(hash);
  });

  it("caps downloads at the daily limit", () => {
    expect(decideDownloadRateLimit(0, 3).allowed).toBe(true);
    expect(decideDownloadRateLimit(2, 3).allowed).toBe(true); // the 3rd
    expect(decideDownloadRateLimit(3, 3).allowed).toBe(false); // the 4th
  });
});

describe("POST /release/publish", () => {
  it("rejects a request without the admin key", async () => {
    const response = await callWorker(
      publishRequest({ version: "1.0.0", sha: "abc" }, SAMPLE_TARBALL, {}),
      envWithKeyset()
    );
    expect(response.status).toBe(401);
  });

  it("503s when no keyset binding is present", async () => {
    const response = await callWorker(
      publishRequest({ version: "1.0.0", sha: "abc" }, SAMPLE_TARBALL),
      { VIDI_PROXY_KEY: OWNER_KEY }
    );
    expect(response.status).toBe(503);
  });

  it("stores the tarball + manifest and computes the sha256 server-side", async () => {
    const env = envWithKeyset();
    const response = await callWorker(
      publishRequest(
        { version: "1.2.3", sha: "deadbeef", notes: "first cut" },
        SAMPLE_TARBALL
      ),
      env
    );
    expect(response.status).toBe(201);
    const json = await response.json();
    expect(json.published).toBe(true);
    expect(json.version).toBe("1.2.3");
    expect(json.bytes).toBe(SAMPLE_TARBALL.byteLength);
    expect(json.sha256).toBe(await sha256HexOfBytes(toArrayBuffer(SAMPLE_TARBALL)));

    const keysetKV = env.VIDI_KEYSET as BinaryInMemoryKV;
    expect(keysetKV.store.has(MANIFEST_KV_NAME)).toBe(true);
    expect(keysetKV.store.has(tarballKvName("1.2.3"))).toBe(true);
  });

  it("rejects an invalid version", async () => {
    const response = await callWorker(
      publishRequest({ version: "bad/version", sha: "abc" }, SAMPLE_TARBALL),
      envWithKeyset()
    );
    expect(response.status).toBe(400);
  });

  it("rejects a missing tarball", async () => {
    const response = await callWorker(
      publishRequest({ version: "1.0.0", sha: "abc" }, null),
      envWithKeyset()
    );
    expect(response.status).toBe(400);
  });
});

describe("GET /release/manifest", () => {
  it("401s without a valid key", async () => {
    const response = await callWorker(
      new Request(releaseUrl("/release/manifest"), { method: "GET" }),
      envWithKeyset()
    );
    expect(response.status).toBe(401);
  });

  it("404s before anything is published", async () => {
    const response = await callWorker(
      new Request(releaseUrl("/release/manifest"), {
        method: "GET",
        headers: { "x-vidi-key": OWNER_KEY },
      }),
      envWithKeyset()
    );
    expect(response.status).toBe(404);
  });

  it("returns the published manifest with a request-origin download url", async () => {
    const env = envWithKeyset();
    await callWorker(
      publishRequest(
        { version: "1.2.3", sha: "deadbeef", notes: "hi" },
        SAMPLE_TARBALL
      ),
      env
    );
    const response = await callWorker(
      new Request(releaseUrl("/release/manifest"), {
        method: "GET",
        headers: { "x-vidi-key": OWNER_KEY },
      }),
      env
    );
    expect(response.status).toBe(200);
    const json = await response.json();
    expect(json.version).toBe("1.2.3");
    expect(json.sha).toBe("deadbeef");
    expect(json.notes).toBe("hi");
    expect(json.url).toBe(
      "https://vidi-proxy.example.dev/release/download/1.2.3"
    );
    expect(json.sha256).toBe(await sha256HexOfBytes(toArrayBuffer(SAMPLE_TARBALL)));
  });

  it("does not consume the install key's chat quota", async () => {
    const env = envWithKeyset();
    const installKey = await mintInstallKey(env);
    await callWorker(
      publishRequest({ version: "1.0.0", sha: "x" }, SAMPLE_TARBALL),
      env
    );
    await callWorker(
      new Request(releaseUrl("/release/manifest"), {
        method: "GET",
        headers: { "x-vidi-key": installKey },
      }),
      env
    );
    const keysetKV = env.VIDI_KEYSET as BinaryInMemoryKV;
    // No chat usage counter is ever written by a manifest check.
    expect(
      [...keysetKV.store.keys()].some((name) => name.startsWith("usage:"))
    ).toBe(false);
  });
});

describe("GET /release/download/<version>", () => {
  async function publishSample(env: TestEnv, version = "1.2.3"): Promise<void> {
    await callWorker(
      publishRequest({ version, sha: "deadbeef" }, SAMPLE_TARBALL),
      env
    );
  }

  it("401s without a valid key", async () => {
    const env = envWithKeyset();
    await publishSample(env);
    const response = await callWorker(
      new Request(releaseUrl("/release/download/1.2.3"), { method: "GET" }),
      env
    );
    expect(response.status).toBe(401);
  });

  it("streams the exact stored tarball bytes to the owner key (unmetered)", async () => {
    const env = envWithKeyset();
    await publishSample(env);
    const response = await callWorker(
      new Request(releaseUrl("/release/download/1.2.3"), {
        method: "GET",
        headers: { "x-vidi-key": OWNER_KEY },
      }),
      env
    );
    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toBe("application/gzip");
    const bytes = new Uint8Array(await response.arrayBuffer());
    expect([...bytes]).toEqual([...SAMPLE_TARBALL]);

    // No download counter is written for the owner key.
    const keysetKV = env.VIDI_KEYSET as BinaryInMemoryKV;
    expect(
      [...keysetKV.store.keys()].some((name) => name.startsWith("release:dl:"))
    ).toBe(false);
  });

  it("404s an unknown version", async () => {
    const env = envWithKeyset();
    await publishSample(env);
    const response = await callWorker(
      new Request(releaseUrl("/release/download/9.9.9"), {
        method: "GET",
        headers: { "x-vidi-key": OWNER_KEY },
      }),
      env
    );
    expect(response.status).toBe(404);
  });

  it("rate-limits an install key's downloads and never touches the chat quota", async () => {
    const env = envWithKeyset();
    await publishSample(env);
    const installKey = await mintInstallKey(env);

    // Exhaust the daily download limit, then the next one 429s.
    for (let index = 0; index < DEFAULT_DAILY_DOWNLOAD_LIMIT; index++) {
      const ok = await callWorker(
        new Request(releaseUrl("/release/download/1.2.3"), {
          method: "GET",
          headers: { "x-vidi-key": installKey },
        }),
        env
      );
      expect(ok.status).toBe(200);
    }
    const overLimit = await callWorker(
      new Request(releaseUrl("/release/download/1.2.3"), {
        method: "GET",
        headers: { "x-vidi-key": installKey },
      }),
      env
    );
    expect(overLimit.status).toBe(429);

    const keysetKV = env.VIDI_KEYSET as BinaryInMemoryKV;
    // Downloads use their own counter, never the chat `usage:` quota.
    expect(
      [...keysetKV.store.keys()].some((name) => name.startsWith("usage:"))
    ).toBe(false);
    expect(
      [...keysetKV.store.keys()].some((name) => name.startsWith("release:dl:"))
    ).toBe(true);
  });
});
