import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import worker from "../src/index";
import {
  INSTALL_KEY_PREFIX,
  keyIdIndexKvName,
  keyRecordKvName,
  usageCounterKvName,
  utcDateStamp,
  type VidiKeysetKVNamespace,
} from "../src/keyset";

// A representative ElevenLabs-shaped id (20 alphanumeric chars).
const ELEVENLABS_CLONE = "21m00Tcm4TlvDq8ikWAM";

/**
 * Install a fetch stub so /tts routing tests can assert the upstream URL + body
 * WITHOUT a real network call. Returns the recorder; the caller reads the last
 * upstream request off it.
 */
function stubUpstreamFetch(): { calls: { url: string; body: string }[] } {
  const calls: { url: string; body: string }[] = [];
  vi.stubGlobal(
    "fetch",
    async (input: RequestInfo | URL, init?: RequestInit) => {
      calls.push({
        url: String(input),
        body: typeof init?.body === "string" ? init.body : "",
      });
      return new Response("fake-audio-bytes", {
        status: 200,
        headers: { "content-type": "audio/mpeg" },
      });
    }
  );
  return { calls };
}

/** In-memory KV standing in for the VIDI_KEYSET binding. */
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

const OWNER_KEY = "owner-shared-key-abc123";

// The worker's Env is structural; the test passes exactly the fields it reads.
type TestEnv = Record<string, unknown>;

function envWithKeyset(): TestEnv {
  return { VIDI_PROXY_KEY: OWNER_KEY, VIDI_KEYSET: new InMemoryKV() };
}

function envWithoutKeyset(): TestEnv {
  return { VIDI_PROXY_KEY: OWNER_KEY };
}

function get(path: string, headers: Record<string, string> = {}): Request {
  return new Request(`https://vidi-proxy.example.dev${path}`, {
    method: "GET",
    headers,
  });
}

function post(
  path: string,
  headers: Record<string, string> = {},
  body?: string
): Request {
  return new Request(`https://vidi-proxy.example.dev${path}`, {
    method: "POST",
    headers,
    body,
  });
}

async function callWorker(request: Request, env: TestEnv): Promise<Response> {
  // The worker's Env type is internal; the test env matches the fields read.
  return worker.fetch(request as never, env as never);
}

async function issueInstallKey(
  env: TestEnv,
  adminHeaders: Record<string, string>,
  body?: string
): Promise<{ status: number; json: any }> {
  const response = await callWorker(
    post("/admin/keys", adminHeaders, body),
    env
  );
  return { status: response.status, json: await response.json() };
}

/**
 * Read the RAW persisted KV record JSON string for a keyId (via the id: index
 * → key: record), bypassing the worker's HTTP surface entirely. Used to assert
 * a rejected admin update left storage byte-unchanged (persist-before-validate
 * regression guard).
 */
async function rawStoredRecordJSON(
  env: TestEnv,
  keyId: string
): Promise<string | null> {
  const keysetKV = env.VIDI_KEYSET as InMemoryKV;
  const keyHash = await keysetKV.get(keyIdIndexKvName(keyId));
  if (!keyHash) {
    return null;
  }
  return keysetKV.get(keyRecordKvName(keyHash));
}

describe("health + method routing", () => {
  it("serves the unauthenticated health check", async () => {
    const response = await callWorker(get("/"), envWithoutKeyset());
    expect(response.status).toBe(200);
    expect(await response.text()).toBe("vidi-proxy ok");
  });

  it("rejects non-POST on a proxied route", async () => {
    const response = await callWorker(get("/chat"), envWithoutKeyset());
    expect(response.status).toBe(405);
  });
});

describe("owner shared key (backwards compatibility)", () => {
  it("authorizes the owner key and is unmetered (no keyset needed)", async () => {
    const env = envWithKeyset();
    // Empty body on /tts fails JSON parse AFTER auth → 400 proves auth passed.
    const response = await callWorker(
      post("/tts", { "x-vidi-key": OWNER_KEY }),
      env
    );
    expect(response.status).toBe(400);
    // No usage counter is ever written for the owner key.
    const keysetKV = env.VIDI_KEYSET as InMemoryKV;
    expect([...keysetKV.store.keys()].some((k) => k.startsWith("usage:"))).toBe(
      false
    );
  });

  it("still works with no keyset bound at all (original behavior)", async () => {
    const response = await callWorker(
      post("/tts", { "x-vidi-key": OWNER_KEY }),
      envWithoutKeyset()
    );
    expect(response.status).toBe(400); // auth passed, then empty-body 400
  });

  it("rejects a wrong key with 401", async () => {
    const response = await callWorker(
      post("/tts", { "x-vidi-key": "not-the-owner-key" }),
      envWithoutKeyset()
    );
    expect(response.status).toBe(401);
  });
});

describe("admin keyset endpoints", () => {
  it("requires the admin key", async () => {
    const { status } = await issueInstallKey(envWithKeyset(), {});
    expect(status).toBe(401);
  });

  it("issues a per-install key (owner proxy key doubles as admin by default)", async () => {
    const env = envWithKeyset();
    const { status, json } = await issueInstallKey(
      env,
      { "x-vidi-admin-key": OWNER_KEY, "content-type": "application/json" },
      JSON.stringify({ label: "test-mac", dailyQuotaRequests: 5 })
    );
    expect(status).toBe(201);
    expect(json.key.startsWith(INSTALL_KEY_PREFIX)).toBe(true);
    expect(json.label).toBe("test-mac");
    expect(json.dailyQuotaRequests).toBe(5);
    expect(json.keyId).toBeTruthy();
  });

  it("prefers a distinct VIDI_ADMIN_KEY when set", async () => {
    const env = { ...envWithKeyset(), VIDI_ADMIN_KEY: "separate-admin" };
    // Owner proxy key is no longer accepted for admin once VIDI_ADMIN_KEY is set.
    const rejected = await issueInstallKey(env, {
      "x-vidi-admin-key": OWNER_KEY,
    });
    expect(rejected.status).toBe(401);
    const accepted = await issueInstallKey(env, {
      "x-vidi-admin-key": "separate-admin",
    });
    expect(accepted.status).toBe(201);
  });

  it("503s admin when no keyset is bound", async () => {
    const { status } = await issueInstallKey(envWithoutKeyset(), {
      "x-vidi-admin-key": OWNER_KEY,
    });
    expect(status).toBe(503);
  });

  it("rejects a fractional dailyQuotaRequests with 400 instead of minting a dead key", async () => {
    const env = envWithKeyset();
    const { status } = await issueInstallKey(
      env,
      { "x-vidi-admin-key": OWNER_KEY, "content-type": "application/json" },
      JSON.stringify({ label: "test-mac", dailyQuotaRequests: 0.5 })
    );
    expect(status).toBe(400);
    // No key was minted for the rejected request.
    const listResponse = await callWorker(
      get("/admin/keys", { "x-vidi-admin-key": OWNER_KEY }),
      env
    );
    expect((await listResponse.json()).keys).toHaveLength(0);
  });

  it("accepts a dailyQuotaRequests of exactly 1", async () => {
    const { status, json } = await issueInstallKey(
      envWithKeyset(),
      { "x-vidi-admin-key": OWNER_KEY, "content-type": "application/json" },
      JSON.stringify({ label: "test-mac", dailyQuotaRequests: 1 })
    );
    expect(status).toBe(201);
    expect(json.dailyQuotaRequests).toBe(1);
  });

  it("lists keys with today's usage and revokes by keyId", async () => {
    const env = envWithKeyset();
    const issued = await issueInstallKey(env, { "x-vidi-admin-key": OWNER_KEY });
    const keyId = issued.json.keyId;

    const listResponse = await callWorker(
      get("/admin/keys", { "x-vidi-admin-key": OWNER_KEY }),
      env
    );
    const listBody = await listResponse.json();
    expect(listBody.keys).toHaveLength(1);
    expect(listBody.keys[0].keyId).toBe(keyId);
    expect(listBody.keys[0].usedRequestsToday).toBe(0);

    const revokeResponse = await callWorker(
      post(
        "/admin/keys/revoke",
        { "x-vidi-admin-key": OWNER_KEY, "content-type": "application/json" },
        JSON.stringify({ keyId })
      ),
      env
    );
    expect(revokeResponse.status).toBe(200);

    const revokeUnknown = await callWorker(
      post(
        "/admin/keys/revoke",
        { "x-vidi-admin-key": OWNER_KEY, "content-type": "application/json" },
        JSON.stringify({ keyId: "nope" })
      ),
      env
    );
    expect(revokeUnknown.status).toBe(404);
  });
});

describe("per-install key on proxied routes", () => {
  let env: TestEnv;
  let installKey: string;
  let installKeyId: string;

  beforeEach(async () => {
    env = envWithKeyset();
    const issued = await issueInstallKey(
      env,
      { "x-vidi-admin-key": OWNER_KEY, "content-type": "application/json" },
      JSON.stringify({ label: "test-mac", dailyQuotaRequests: 1 })
    );
    installKey = issued.json.key;
    installKeyId = issued.json.keyId;
  });

  it("authorizes a valid install key and meters its usage", async () => {
    const response = await callWorker(
      post("/tts", { "x-vidi-key": installKey }),
      env
    );
    expect(response.status).toBe(400); // auth passed, then empty-body 400
    const keysetKV = env.VIDI_KEYSET as InMemoryKV;
    const usage = await keysetKV.get(
      usageCounterKvName(installKeyId, utcDateStamp(new Date()))
    );
    expect(usage).toBe("1");
  });

  it("returns 429 once the daily quota is exhausted", async () => {
    await callWorker(post("/tts", { "x-vidi-key": installKey }), env); // 1st, within quota=1
    const overQuota = await callWorker(
      post("/tts", { "x-vidi-key": installKey }),
      env
    );
    expect(overQuota.status).toBe(429);
  });

  it("rejects a revoked install key with 401", async () => {
    await callWorker(
      post(
        "/admin/keys/revoke",
        { "x-vidi-admin-key": OWNER_KEY, "content-type": "application/json" },
        JSON.stringify({ keyId: installKeyId })
      ),
      env
    );
    const response = await callWorker(
      post("/tts", { "x-vidi-key": installKey }),
      env
    );
    expect(response.status).toBe(401);
  });

  it("rejects an unknown key that merely has the install prefix", async () => {
    const response = await callWorker(
      post("/tts", { "x-vidi-key": INSTALL_KEY_PREFIX + "deadbeef" }),
      env
    );
    expect(response.status).toBe(401);
  });
});

const TTS_HEADERS = { "content-type": "application/json" };

describe("per-request voiceId on /tts (routing + entitlements)", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("keeps the global default byte-identical when no voiceId is sent (owner)", async () => {
    const { calls } = stubUpstreamFetch();
    const env = { ...envWithKeyset(), XAI_API_KEY: "xai-secret", GROK_VOICE_ID: "ara" };
    const response = await callWorker(
      post("/tts", { ...TTS_HEADERS, "x-vidi-key": OWNER_KEY }, JSON.stringify({ text: "hi" })),
      env
    );
    expect(response.status).toBe(200);
    expect(calls[0].url).toBe("https://api.x.ai/v1/tts");
    expect(JSON.parse(calls[0].body).voice_id).toBe("ara");
  });

  it("routes an entitled global Grok voice to the grok upstream", async () => {
    const { calls } = stubUpstreamFetch();
    const env = { ...envWithKeyset(), XAI_API_KEY: "xai-secret" };
    const issued = await issueInstallKey(
      env,
      { "x-vidi-admin-key": OWNER_KEY, ...TTS_HEADERS },
      JSON.stringify({ label: "test-mac", dailyQuotaRequests: 100 })
    );
    const response = await callWorker(
      post(
        "/tts",
        { ...TTS_HEADERS, "x-vidi-key": issued.json.key },
        JSON.stringify({ text: "hi", voiceId: "eve" })
      ),
      env
    );
    expect(response.status).toBe(200);
    expect(calls[0].url).toBe("https://api.x.ai/v1/tts");
    expect(JSON.parse(calls[0].body).voice_id).toBe("eve");
  });

  it("403s an EL voice the keyset key is not entitled to (never hits upstream)", async () => {
    const { calls } = stubUpstreamFetch();
    const env = { ...envWithKeyset(), XAI_API_KEY: "xai-secret", ELEVENLABS_API_KEY: "el-secret" };
    const issued = await issueInstallKey(
      env,
      { "x-vidi-admin-key": OWNER_KEY, ...TTS_HEADERS },
      JSON.stringify({ label: "test-mac", dailyQuotaRequests: 100 })
    );
    const response = await callWorker(
      post(
        "/tts",
        { ...TTS_HEADERS, "x-vidi-key": issued.json.key },
        JSON.stringify({ text: "hi", voiceId: ELEVENLABS_CLONE })
      ),
      env
    );
    expect(response.status).toBe(403);
    expect(calls).toHaveLength(0);
  });

  it("403s an unknown-shaped voiceId", async () => {
    const env = { ...envWithKeyset(), XAI_API_KEY: "xai-secret" };
    const issued = await issueInstallKey(
      env,
      { "x-vidi-admin-key": OWNER_KEY, ...TTS_HEADERS },
      JSON.stringify({ label: "test-mac", dailyQuotaRequests: 100 })
    );
    const response = await callWorker(
      post(
        "/tts",
        { ...TTS_HEADERS, "x-vidi-key": issued.json.key },
        JSON.stringify({ text: "hi", voiceId: "not-a-voice" })
      ),
      env
    );
    expect(response.status).toBe(403);
  });

  it("400s a non-string voiceId", async () => {
    const response = await callWorker(
      post(
        "/tts",
        { ...TTS_HEADERS, "x-vidi-key": OWNER_KEY },
        JSON.stringify({ text: "hi", voiceId: 42 })
      ),
      { ...envWithKeyset(), XAI_API_KEY: "xai-secret" }
    );
    expect(response.status).toBe(400);
  });

  it("routes an entitled EL voice to the ElevenLabs upstream when the secret is set", async () => {
    const { calls } = stubUpstreamFetch();
    const env = { ...envWithKeyset(), ELEVENLABS_API_KEY: "el-secret" };
    const issued = await issueInstallKey(
      env,
      { "x-vidi-admin-key": OWNER_KEY, ...TTS_HEADERS },
      JSON.stringify({
        label: "test-mac",
        dailyQuotaRequests: 100,
        allowedVoiceIds: [ELEVENLABS_CLONE],
      })
    );
    const response = await callWorker(
      post(
        "/tts",
        { ...TTS_HEADERS, "x-vidi-key": issued.json.key },
        JSON.stringify({ text: "hi", voiceId: ELEVENLABS_CLONE })
      ),
      env
    );
    expect(response.status).toBe(200);
    expect(calls[0].url).toBe(`https://api.elevenlabs.io/v1/text-to-speech/${ELEVENLABS_CLONE}`);
  });

  it("503s an entitled EL voice when ELEVENLABS_API_KEY is absent (never hits upstream)", async () => {
    const { calls } = stubUpstreamFetch();
    const env = { ...envWithKeyset() }; // no ELEVENLABS_API_KEY
    const issued = await issueInstallKey(
      env,
      { "x-vidi-admin-key": OWNER_KEY, ...TTS_HEADERS },
      JSON.stringify({
        label: "test-mac",
        dailyQuotaRequests: 100,
        allowedVoiceIds: [ELEVENLABS_CLONE],
      })
    );
    const response = await callWorker(
      post(
        "/tts",
        { ...TTS_HEADERS, "x-vidi-key": issued.json.key },
        JSON.stringify({ text: "hi", voiceId: ELEVENLABS_CLONE })
      ),
      env
    );
    expect(response.status).toBe(503);
    expect(calls).toHaveLength(0);
  });

  it("uses the key's default EL voice when no explicit voiceId is sent", async () => {
    const { calls } = stubUpstreamFetch();
    const env = { ...envWithKeyset(), ELEVENLABS_API_KEY: "el-secret" };
    const issued = await issueInstallKey(
      env,
      { "x-vidi-admin-key": OWNER_KEY, ...TTS_HEADERS },
      JSON.stringify({
        label: "test-mac",
        dailyQuotaRequests: 100,
        allowedVoiceIds: [ELEVENLABS_CLONE],
        defaultVoiceId: ELEVENLABS_CLONE,
      })
    );
    const response = await callWorker(
      post("/tts", { ...TTS_HEADERS, "x-vidi-key": issued.json.key }, JSON.stringify({ text: "hi" })),
      env
    );
    expect(response.status).toBe(200);
    expect(calls[0].url).toBe(`https://api.elevenlabs.io/v1/text-to-speech/${ELEVENLABS_CLONE}`);
  });
});

describe("admin mint/update with voice entitlements", () => {
  it("mints a key with entitlements and echoes them back", async () => {
    const env = envWithKeyset();
    const { status, json } = await issueInstallKey(
      env,
      { "x-vidi-admin-key": OWNER_KEY, ...TTS_HEADERS },
      JSON.stringify({
        label: "test-mac",
        allowedVoiceIds: [ELEVENLABS_CLONE, "eve"],
        defaultVoiceId: "eve",
      })
    );
    expect(status).toBe(201);
    expect(json.allowedVoiceIds).toEqual([ELEVENLABS_CLONE, "eve"]);
    expect(json.defaultVoiceId).toBe("eve");
  });

  it("400s a mint with an unroutable allowed voiceId", async () => {
    const { status } = await issueInstallKey(
      envWithKeyset(),
      { "x-vidi-admin-key": OWNER_KEY, ...TTS_HEADERS },
      JSON.stringify({ label: "x", allowedVoiceIds: ["garbage"] })
    );
    expect(status).toBe(400);
  });

  it("adds a clone to an existing key via /admin/keys/update (addAllowedVoiceIds)", async () => {
    const env = envWithKeyset();
    const issued = await issueInstallKey(
      env,
      { "x-vidi-admin-key": OWNER_KEY, ...TTS_HEADERS },
      JSON.stringify({ label: "test-mac", dailyQuotaRequests: 100 })
    );
    const keyId = issued.json.keyId;

    const updateResponse = await callWorker(
      post(
        "/admin/keys/update",
        { "x-vidi-admin-key": OWNER_KEY, ...TTS_HEADERS },
        JSON.stringify({ keyId, addAllowedVoiceIds: [ELEVENLABS_CLONE], defaultVoiceId: ELEVENLABS_CLONE })
      ),
      env
    );
    expect(updateResponse.status).toBe(200);
    const updated = await updateResponse.json();
    expect(updated.allowedVoiceIds).toEqual([ELEVENLABS_CLONE]);
    expect(updated.defaultVoiceId).toBe(ELEVENLABS_CLONE);

    // The list endpoint reflects the persisted entitlement.
    const listResponse = await callWorker(
      get("/admin/keys", { "x-vidi-admin-key": OWNER_KEY }),
      env
    );
    const listed = (await listResponse.json()).keys.find((k: any) => k.keyId === keyId);
    expect(listed.allowedVoiceIds).toEqual([ELEVENLABS_CLONE]);
  });

  it("updates a key by unique label", async () => {
    const env = envWithKeyset();
    await issueInstallKey(
      env,
      { "x-vidi-admin-key": OWNER_KEY, ...TTS_HEADERS },
      JSON.stringify({ label: "solo-label", dailyQuotaRequests: 100 })
    );
    const updateResponse = await callWorker(
      post(
        "/admin/keys/update",
        { "x-vidi-admin-key": OWNER_KEY, ...TTS_HEADERS },
        JSON.stringify({ label: "solo-label", addAllowedVoiceIds: [ELEVENLABS_CLONE] })
      ),
      env
    );
    expect(updateResponse.status).toBe(200);
    expect((await updateResponse.json()).allowedVoiceIds).toEqual([ELEVENLABS_CLONE]);
  });

  it("404s an update for an unknown keyId", async () => {
    const response = await callWorker(
      post(
        "/admin/keys/update",
        { "x-vidi-admin-key": OWNER_KEY, ...TTS_HEADERS },
        JSON.stringify({ keyId: "nope", addAllowedVoiceIds: [ELEVENLABS_CLONE] })
      ),
      envWithKeyset()
    );
    expect(response.status).toBe(404);
  });

  it("400s an update whose merged result leaves the default unentitled, and persists NOTHING (regression: persist-before-validate)", async () => {
    const env = envWithKeyset();
    const issued = await issueInstallKey(
      env,
      { "x-vidi-admin-key": OWNER_KEY, ...TTS_HEADERS },
      JSON.stringify({ label: "test-mac", dailyQuotaRequests: 100 })
    );
    const keyId = issued.json.keyId;
    const storedBeforeRejectedUpdate = await rawStoredRecordJSON(env, keyId);

    const response = await callWorker(
      post(
        "/admin/keys/update",
        { "x-vidi-admin-key": OWNER_KEY, ...TTS_HEADERS },
        // Setting an EL default without entitling it must be rejected.
        JSON.stringify({ keyId, defaultVoiceId: ELEVENLABS_CLONE })
      ),
      env
    );
    expect(response.status).toBe(400);

    // The rejected update must never have reached KV: the stored record is
    // byte-for-byte identical to before the request, so a subsequent /tts with
    // no voiceId cannot pick up a "rejected" default (the vulnerability this
    // guards: a 400 that still persisted the unentitled default, silently
    // granting the voice on the next no-voiceId TTS call).
    const storedAfterRejectedUpdate = await rawStoredRecordJSON(env, keyId);
    expect(storedAfterRejectedUpdate).toBe(storedBeforeRejectedUpdate);
    expect(JSON.parse(storedAfterRejectedUpdate!).defaultVoiceId).toBeUndefined();
  });

  it("400s a garbage allowedVoiceIds replace WITHOUT first discarding the existing valid set (regression: persist-before-validate data loss)", async () => {
    const env = envWithKeyset();
    const issued = await issueInstallKey(
      env,
      { "x-vidi-admin-key": OWNER_KEY, ...TTS_HEADERS },
      JSON.stringify({
        label: "test-mac",
        dailyQuotaRequests: 100,
        allowedVoiceIds: [ELEVENLABS_CLONE],
      })
    );
    const keyId = issued.json.keyId;
    const storedBeforeRejectedReplace = await rawStoredRecordJSON(env, keyId);

    const response = await callWorker(
      post(
        "/admin/keys/update",
        { "x-vidi-admin-key": OWNER_KEY, ...TTS_HEADERS },
        // An unroutable replacement set must be rejected outright, not applied
        // and then reported invalid.
        JSON.stringify({ keyId, allowedVoiceIds: ["garbage-id"] })
      ),
      env
    );
    expect(response.status).toBe(400);

    const storedAfterRejectedReplace = await rawStoredRecordJSON(env, keyId);
    expect(storedAfterRejectedReplace).toBe(storedBeforeRejectedReplace);
    expect(JSON.parse(storedAfterRejectedReplace!).allowedVoiceIds).toEqual([ELEVENLABS_CLONE]);
  });
});

describe("GET /voices catalog", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("returns the grok stock plus the key's entitled voices, unmetered", async () => {
    const env = envWithKeyset();
    const issued = await issueInstallKey(
      env,
      { "x-vidi-admin-key": OWNER_KEY, ...TTS_HEADERS },
      JSON.stringify({
        label: "test-mac",
        dailyQuotaRequests: 1,
        allowedVoiceIds: [ELEVENLABS_CLONE],
        defaultVoiceId: ELEVENLABS_CLONE,
      })
    );
    const response = await callWorker(
      get("/voices", { "x-vidi-key": issued.json.key }),
      env
    );
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toContain("max-age");
    const body = await response.json();
    const ids = body.voices.map((v: any) => v.id);
    expect(ids).toContain("ara");
    expect(ids).toContain(ELEVENLABS_CLONE);
    expect(body.voices.find((v: any) => v.id === ELEVENLABS_CLONE).isDefault).toBe(true);

    // The catalog fetch does NOT consume the (tiny) daily quota.
    const keysetKV = env.VIDI_KEYSET as InMemoryKV;
    expect([...keysetKV.store.keys()].some((k) => k.startsWith("usage:"))).toBe(false);
  });

  it("401s a /voices request with no key", async () => {
    const response = await callWorker(get("/voices"), envWithKeyset());
    expect(response.status).toBe(401);
  });
});
