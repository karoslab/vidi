import { describe, it, expect, afterEach, vi } from "vitest";
import worker from "../src/index";
import {
  INSTALL_KEY_PREFIX,
  type VidiKeysetKVNamespace,
} from "../src/keyset";
import {
  buildFeedbackDiscordContent,
  FEEDBACK_DAILY_CAP,
  WEEKLY_SUMMARY_WEEKLY_CAP,
  MAX_FEEDBACK_BODY_BYTES,
} from "../src/feedback";

/** In-memory KV standing in for the VIDI_KEYSET binding (mirrors worker.test.ts). */
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
const WEBHOOK_URL = "https://discord.example/api/webhooks/123/token";

type TestEnv = Record<string, unknown>;

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
  return worker.fetch(request as never, env as never);
}

/**
 * Stub the webhook fetch and record every outbound call so a test can assert the
 * posted content (and that NO call happened on the unset-secret path).
 */
function stubWebhookFetch(status = 200): { calls: { url: string; body: string }[] } {
  const calls: { url: string; body: string }[] = [];
  vi.stubGlobal("fetch", async (input: RequestInfo | URL, init?: RequestInit) => {
    calls.push({
      url: String(input),
      body: typeof init?.body === "string" ? init.body : "",
    });
    return new Response("", { status });
  });
  return { calls };
}

async function mintInstallKey(env: TestEnv, label: string): Promise<string> {
  const response = await callWorker(
    post(
      "/admin/keys",
      { "x-vidi-admin-key": OWNER_KEY, "content-type": "application/json" },
      JSON.stringify({ label })
    ),
    env
  );
  const json = (await response.json()) as { key: string };
  return json.key;
}

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("POST /feedback — pure Discord content builder", () => {
  it("names the kind + label and includes the human text", () => {
    const content = buildFeedbackDiscordContent(
      "feedback",
      "test-mac",
      "the buttons are too small"
    );
    expect(content).toContain("test-mac");
    expect(content).toContain("Feedback");
    expect(content).toContain("the buttons are too small");
  });

  it("puts a report in a collapsed code fence and trims the report, not the text", () => {
    const longReport = "R".repeat(5000);
    const content = buildFeedbackDiscordContent(
      "feedback",
      "test-mac",
      "short note",
      longReport
    );
    expect(content).toContain("short note");
    expect(content).toContain("```");
    // Discord's ceiling is respected.
    expect(content.length).toBeLessThanOrEqual(1990);
  });

  it("labels the weekly summary distinctly", () => {
    const content = buildFeedbackDiscordContent(
      "weekly-summary",
      "test-mac",
      "5 sessions, 2 provider-fail"
    );
    expect(content).toContain("Weekly health");
  });
});

describe("POST /feedback — route", () => {
  it("401s without a valid key", async () => {
    const env = { VIDI_PROXY_KEY: OWNER_KEY, VIDI_FEEDBACK_WEBHOOK: WEBHOOK_URL };
    const { calls } = stubWebhookFetch();
    const response = await callWorker(
      post("/feedback", { "content-type": "application/json" }, JSON.stringify({ text: "hi" })),
      env
    );
    expect(response.status).toBe(401);
    expect(calls).toHaveLength(0);
  });

  it("owner key happy path posts to the webhook with the owner label", async () => {
    const env = { VIDI_PROXY_KEY: OWNER_KEY, VIDI_FEEDBACK_WEBHOOK: WEBHOOK_URL };
    const { calls } = stubWebhookFetch();
    const response = await callWorker(
      post(
        "/feedback",
        { "x-vidi-key": OWNER_KEY, "content-type": "application/json" },
        JSON.stringify({ text: "love it" })
      ),
      env
    );
    expect(response.status).toBe(200);
    expect(calls).toHaveLength(1);
    expect(calls[0].url).toBe(WEBHOOK_URL);
    const posted = JSON.parse(calls[0].body) as { content: string };
    expect(posted.content).toContain("owner");
    expect(posted.content).toContain("love it");
  });

  it("keyset key happy path posts with the install's own label", async () => {
    const env = {
      VIDI_PROXY_KEY: OWNER_KEY,
      VIDI_KEYSET: new InMemoryKV(),
      VIDI_FEEDBACK_WEBHOOK: WEBHOOK_URL,
    };
    const installKey = await mintInstallKey(env, "test-mac");
    const { calls } = stubWebhookFetch();
    const response = await callWorker(
      post(
        "/feedback",
        { "x-vidi-key": installKey, "content-type": "application/json" },
        JSON.stringify({ text: "how do I pause it" })
      ),
      env
    );
    expect(response.status).toBe(200);
    const posted = JSON.parse(calls[0].body) as { content: string };
    expect(posted.content).toContain("test-mac");
  });

  it("503s with ZERO upstream fetch when the webhook secret is unset", async () => {
    const env = { VIDI_PROXY_KEY: OWNER_KEY };
    const { calls } = stubWebhookFetch();
    const response = await callWorker(
      post(
        "/feedback",
        { "x-vidi-key": OWNER_KEY, "content-type": "application/json" },
        JSON.stringify({ text: "hello" })
      ),
      env
    );
    expect(response.status).toBe(503);
    expect(calls).toHaveLength(0);
    // The webhook URL is never echoed (it was unset, but assert the shape).
    expect(JSON.stringify(await response.json())).not.toContain("discord.example");
  });

  it("413s a body over the size cap without fetching", async () => {
    const env = { VIDI_PROXY_KEY: OWNER_KEY, VIDI_FEEDBACK_WEBHOOK: WEBHOOK_URL };
    const { calls } = stubWebhookFetch();
    const huge = "x".repeat(MAX_FEEDBACK_BODY_BYTES + 100);
    const response = await callWorker(
      post(
        "/feedback",
        { "x-vidi-key": OWNER_KEY, "content-type": "application/json" },
        JSON.stringify({ text: huge })
      ),
      env
    );
    expect(response.status).toBe(413);
    expect(calls).toHaveLength(0);
  });

  it("400s a missing text field", async () => {
    const env = { VIDI_PROXY_KEY: OWNER_KEY, VIDI_FEEDBACK_WEBHOOK: WEBHOOK_URL };
    stubWebhookFetch();
    const response = await callWorker(
      post(
        "/feedback",
        { "x-vidi-key": OWNER_KEY, "content-type": "application/json" },
        JSON.stringify({ report: "no text" })
      ),
      env
    );
    expect(response.status).toBe(400);
  });

  it("429s a keyset install past the daily feedback cap", async () => {
    const env = {
      VIDI_PROXY_KEY: OWNER_KEY,
      VIDI_KEYSET: new InMemoryKV(),
      VIDI_FEEDBACK_WEBHOOK: WEBHOOK_URL,
    };
    const installKey = await mintInstallKey(env, "test-mac");
    stubWebhookFetch();
    // Exhaust the daily cap.
    for (let i = 0; i < FEEDBACK_DAILY_CAP; i++) {
      const ok = await callWorker(
        post(
          "/feedback",
          { "x-vidi-key": installKey, "content-type": "application/json" },
          JSON.stringify({ text: `note ${i}` })
        ),
        env
      );
      expect(ok.status).toBe(200);
    }
    const overCap = await callWorker(
      post(
        "/feedback",
        { "x-vidi-key": installKey, "content-type": "application/json" },
        JSON.stringify({ text: "one too many" })
      ),
      env
    );
    expect(overCap.status).toBe(429);
  });

  it("429s a keyset install past the weekly-summary cap (separate counter)", async () => {
    const env = {
      VIDI_PROXY_KEY: OWNER_KEY,
      VIDI_KEYSET: new InMemoryKV(),
      VIDI_FEEDBACK_WEBHOOK: WEBHOOK_URL,
    };
    const installKey = await mintInstallKey(env, "test-mac");
    stubWebhookFetch();
    for (let i = 0; i < WEEKLY_SUMMARY_WEEKLY_CAP; i++) {
      const ok = await callWorker(
        post(
          "/feedback",
          { "x-vidi-key": installKey, "content-type": "application/json" },
          JSON.stringify({ text: "weekly stats", kind: "weekly-summary" })
        ),
        env
      );
      expect(ok.status).toBe(200);
    }
    const overCap = await callWorker(
      post(
        "/feedback",
        { "x-vidi-key": installKey, "content-type": "application/json" },
        JSON.stringify({ text: "weekly stats", kind: "weekly-summary" })
      ),
      env
    );
    expect(overCap.status).toBe(429);
  });
});
