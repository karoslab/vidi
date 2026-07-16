import { describe, it, expect } from "vitest";
import {
  GLOBAL_VOICE_ALLOWLIST,
  catalogForKey,
  isVoiceEntitledForKey,
  looksLikeElevenLabsVoiceId,
  resolveVoiceSelection,
  routeForVoiceId,
  validateEntitlementSelection,
} from "../src/voices";

// A representative ElevenLabs-shaped id (20 alphanumeric chars).
const ELEVENLABS_CLONE = "21m00Tcm4TlvDq8ikWAM";

describe("routeForVoiceId", () => {
  it("routes stock Grok voices to grok", () => {
    for (const grokVoice of GLOBAL_VOICE_ALLOWLIST) {
      expect(routeForVoiceId(grokVoice)).toBe("grok");
    }
  });
  it("routes an ElevenLabs-shaped id to elevenlabs", () => {
    expect(routeForVoiceId(ELEVENLABS_CLONE)).toBe("elevenlabs");
  });
  it("returns null for an unknown/unsupported id", () => {
    expect(routeForVoiceId("not-a-voice")).toBeNull();
    expect(routeForVoiceId("ara-but-longer")).toBeNull();
    expect(routeForVoiceId("")).toBeNull();
    // Right length but contains a non-alphanumeric char → not an EL id.
    expect(routeForVoiceId("21m00Tcm4TlvDq8ikWA-")).toBeNull();
  });
});

describe("looksLikeElevenLabsVoiceId", () => {
  it("matches only 20-char alphanumeric tokens", () => {
    expect(looksLikeElevenLabsVoiceId(ELEVENLABS_CLONE)).toBe(true);
    expect(looksLikeElevenLabsVoiceId("short")).toBe(false);
    expect(looksLikeElevenLabsVoiceId(ELEVENLABS_CLONE + "x")).toBe(false);
  });
});

describe("isVoiceEntitledForKey", () => {
  it("always allows a global stock voice regardless of the key's list", () => {
    expect(isVoiceEntitledForKey("ara", undefined, undefined)).toBe(true);
    expect(isVoiceEntitledForKey("leo", [], undefined)).toBe(true);
  });
  it("allows a non-global voice only via the key's allowed list or default", () => {
    expect(isVoiceEntitledForKey(ELEVENLABS_CLONE, [ELEVENLABS_CLONE], undefined)).toBe(true);
    expect(isVoiceEntitledForKey(ELEVENLABS_CLONE, undefined, ELEVENLABS_CLONE)).toBe(true);
    expect(isVoiceEntitledForKey(ELEVENLABS_CLONE, ["other"], undefined)).toBe(false);
    expect(isVoiceEntitledForKey(ELEVENLABS_CLONE, undefined, undefined)).toBe(false);
  });
});

describe("resolveVoiceSelection", () => {
  it("falls to the global default when no voiceId is in play (back-compat)", () => {
    expect(
      resolveVoiceSelection({ isOwner: false, elevenLabsConfigured: true })
    ).toEqual({ kind: "global-default" });
  });

  it("resolves an entitled global Grok voice for a keyset key", () => {
    expect(
      resolveVoiceSelection({
        requestedVoiceId: "eve",
        isOwner: false,
        elevenLabsConfigured: false,
      })
    ).toEqual({ kind: "resolved", voiceId: "eve", route: "grok" });
  });

  it("uses the key's default voice when no explicit voiceId is sent", () => {
    expect(
      resolveVoiceSelection({
        keyDefaultVoiceId: ELEVENLABS_CLONE,
        keyAllowedVoiceIds: [ELEVENLABS_CLONE],
        isOwner: false,
        elevenLabsConfigured: true,
      })
    ).toEqual({ kind: "resolved", voiceId: ELEVENLABS_CLONE, route: "elevenlabs" });
  });

  it("prefers the explicit request voiceId over the key's default", () => {
    expect(
      resolveVoiceSelection({
        requestedVoiceId: "rex",
        keyDefaultVoiceId: ELEVENLABS_CLONE,
        keyAllowedVoiceIds: [ELEVENLABS_CLONE],
        isOwner: false,
        elevenLabsConfigured: true,
      })
    ).toEqual({ kind: "resolved", voiceId: "rex", route: "grok" });
  });

  it("forbids an EL voice the keyset key is not entitled to", () => {
    const result = resolveVoiceSelection({
      requestedVoiceId: ELEVENLABS_CLONE,
      keyAllowedVoiceIds: ["other-clone-aaaaaaaa"],
      isOwner: false,
      elevenLabsConfigured: true,
    });
    expect(result.kind).toBe("forbidden");
  });

  it("forbids an unknown-shaped voiceId", () => {
    const result = resolveVoiceSelection({
      requestedVoiceId: "definitely-not-a-voice",
      isOwner: false,
      elevenLabsConfigured: true,
    });
    expect(result.kind).toBe("forbidden");
  });

  it("marks an entitled EL voice unavailable when ElevenLabs is not configured", () => {
    const result = resolveVoiceSelection({
      requestedVoiceId: ELEVENLABS_CLONE,
      keyAllowedVoiceIds: [ELEVENLABS_CLONE],
      isOwner: false,
      elevenLabsConfigured: false,
    });
    expect(result.kind).toBe("unavailable");
  });

  it("lets the owner use any routable voiceId without an entitlement", () => {
    expect(
      resolveVoiceSelection({
        requestedVoiceId: ELEVENLABS_CLONE,
        isOwner: true,
        elevenLabsConfigured: true,
      })
    ).toEqual({ kind: "resolved", voiceId: ELEVENLABS_CLONE, route: "elevenlabs" });
  });
});

describe("catalogForKey", () => {
  it("lists the global Grok stock voices for a key with no extras", () => {
    const catalog = catalogForKey(undefined, undefined);
    expect(catalog.map((entry) => entry.id)).toEqual([...GLOBAL_VOICE_ALLOWLIST]);
    expect(catalog.every((entry) => entry.provider === "grok")).toBe(true);
    expect(catalog.some((entry) => entry.isDefault)).toBe(false);
  });

  it("appends entitled custom voices and marks the default", () => {
    const catalog = catalogForKey([ELEVENLABS_CLONE], ELEVENLABS_CLONE);
    const custom = catalog.find((entry) => entry.id === ELEVENLABS_CLONE);
    expect(custom).toEqual({
      id: ELEVENLABS_CLONE,
      label: ELEVENLABS_CLONE,
      provider: "elevenlabs",
      isDefault: true,
    });
    // A stock Grok default is marked too.
    expect(catalogForKey(undefined, "ara").find((entry) => entry.id === "ara")?.isDefault).toBe(true);
  });

  it("never advertises an unroutable entitled id", () => {
    const catalog = catalogForKey(["garbage-id"], undefined);
    expect(catalog.some((entry) => entry.id === "garbage-id")).toBe(false);
  });
});

describe("validateEntitlementSelection", () => {
  it("accepts a valid selection", () => {
    expect(validateEntitlementSelection([ELEVENLABS_CLONE], ELEVENLABS_CLONE)).toBeNull();
    expect(validateEntitlementSelection(["eve"], "ara")).toBeNull();
    expect(validateEntitlementSelection(undefined, undefined)).toBeNull();
  });
  it("rejects an unroutable id in allowedVoiceIds", () => {
    expect(validateEntitlementSelection(["not-a-voice"], undefined)).toMatch(/allowedVoiceIds/);
  });
  it("rejects a defaultVoiceId that is neither global nor in the allowed list", () => {
    expect(validateEntitlementSelection([], ELEVENLABS_CLONE)).toMatch(/defaultVoiceId/);
  });
});
