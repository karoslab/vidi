/**
 * Vidi Proxy Worker — per-voice entitlements (voice router + catalog).
 *
 * vidi-chat sends an optional per-request `voiceId` on `/tts`. The worker must
 * decide, for THIS caller, (a) whether the voiceId is allowed and (b) which TTS
 * upstream to route it to — WITHOUT ever forwarding an arbitrary id into the
 * ElevenLabs URL for a keyset key that is not entitled to it.
 *
 * Two voice families exist today:
 *   - Grok stock voices (ara/eve/rex/sal/leo) — served by api.x.ai/v1/tts. These
 *     are the GLOBAL_VOICE_ALLOWLIST: any keyset key may select any of them.
 *   - ElevenLabs voices (20-char alphanumeric ids, e.g. a consented voice clone)
 *     — served by api.elevenlabs.io. A keyset key may select one ONLY if it is
 *     listed in that key's `allowedVoiceIds` (or is that key's `defaultVoiceId`),
 *     AND the ElevenLabs secret is configured on the worker.
 *
 * All decisions here are pure (no env, no network, no KV) so they are unit-tested
 * directly and the KV-backed keyset stays the only side-effecting layer.
 */

export type TTSProviderRoute = "grok" | "elevenlabs";

export interface VoiceCatalogEntry {
  id: string;
  label: string;
  provider: TTSProviderRoute;
  isDefault: boolean;
}

/**
 * The stock Grok voices, globally selectable by every keyset key. This IS the
 * GLOBAL_VOICE_ALLOWLIST — an id in this set never needs a per-key entitlement.
 */
export const GROK_STOCK_VOICES: ReadonlyArray<{ id: string; label: string }> = [
  { id: "ara", label: "Ara (Grok)" },
  { id: "eve", label: "Eve (Grok)" },
  { id: "rex", label: "Rex (Grok)" },
  { id: "sal", label: "Sal (Grok)" },
  { id: "leo", label: "Leo (Grok)" },
];

/** The stock Grok voice ids — the global allowlist available to any key. */
export const GLOBAL_VOICE_ALLOWLIST: ReadonlyArray<string> = GROK_STOCK_VOICES.map(
  (voice) => voice.id
);

/** True when the voiceId is one of the stock Grok voices (routes to Grok TTS). */
export function isGrokStockVoice(voiceId: string): boolean {
  return GLOBAL_VOICE_ALLOWLIST.includes(voiceId);
}

// ElevenLabs voice ids are 20-character alphanumeric tokens (e.g.
// "21m00Tcm4TlvDq8ikWAM"). This shape is how the router tells an ElevenLabs
// voice apart from a stock Grok voice name; a value matching neither is unknown.
const ELEVENLABS_VOICE_ID_PATTERN = /^[A-Za-z0-9]{20}$/;

/** True when the voiceId is shaped like an ElevenLabs voice id. */
export function looksLikeElevenLabsVoiceId(voiceId: string): boolean {
  return ELEVENLABS_VOICE_ID_PATTERN.test(voiceId);
}

/**
 * Which TTS upstream a voiceId routes to, purely from its shape:
 * a known Grok stock voice → "grok"; an ElevenLabs-shaped id → "elevenlabs";
 * anything else → null (unknown / unsupported).
 */
export function routeForVoiceId(voiceId: string): TTSProviderRoute | null {
  if (isGrokStockVoice(voiceId)) {
    return "grok";
  }
  if (looksLikeElevenLabsVoiceId(voiceId)) {
    return "elevenlabs";
  }
  return null;
}

/**
 * Whether a keyset key is entitled to a voiceId: a global (Grok stock) voice is
 * always allowed; otherwise the id must be the key's default or in its allowed
 * list. Owner requests skip this check entirely (handled by the caller).
 */
export function isVoiceEntitledForKey(
  voiceId: string,
  allowedVoiceIds: ReadonlyArray<string> | undefined,
  defaultVoiceId: string | undefined
): boolean {
  if (GLOBAL_VOICE_ALLOWLIST.includes(voiceId)) {
    return true;
  }
  if (defaultVoiceId !== undefined && defaultVoiceId === voiceId) {
    return true;
  }
  if (allowedVoiceIds !== undefined && allowedVoiceIds.includes(voiceId)) {
    return true;
  }
  return false;
}

export interface VoiceResolutionInput {
  /** The explicit `body.voiceId` on the request, if any. */
  requestedVoiceId?: string;
  /** The key's stored default voice, used when no explicit voiceId is sent. */
  keyDefaultVoiceId?: string;
  /** The key's entitled voice ids (ignored for the owner). */
  keyAllowedVoiceIds?: ReadonlyArray<string>;
  /** True for the owner (VIDI_PROXY_KEY) — skips the entitlement check. */
  isOwner: boolean;
  /** Whether ELEVENLABS_API_KEY is configured on the worker. */
  elevenLabsConfigured: boolean;
}

export type VoiceResolution =
  // No voiceId in play → keep the worker's existing global TTS behavior
  // (TTS_PROVIDER + GROK_VOICE_ID/ELEVENLABS_VOICE_ID vars). Byte-identical for
  // callers that never send a voiceId.
  | { kind: "global-default" }
  // A specific voiceId is entitled and routable.
  | { kind: "resolved"; voiceId: string; route: TTSProviderRoute }
  // Unknown-shaped or not-entitled voiceId → 403.
  | { kind: "forbidden"; voiceId: string; reason: string }
  // Entitled ElevenLabs voice, but the ElevenLabs secret is not configured → 503.
  | { kind: "unavailable"; voiceId: string; reason: string };

/**
 * Resolve which voice (and upstream) a TTS request should use, applying
 * entitlement + routing rules. Precedence: explicit request voiceId → key's
 * default voiceId → global default (existing behavior). Pure.
 */
export function resolveVoiceSelection(
  input: VoiceResolutionInput
): VoiceResolution {
  const requestedVoiceId = normalizeVoiceId(input.requestedVoiceId);
  const keyDefaultVoiceId = normalizeVoiceId(input.keyDefaultVoiceId);
  const effectiveVoiceId = requestedVoiceId ?? keyDefaultVoiceId;

  if (effectiveVoiceId === undefined) {
    return { kind: "global-default" };
  }

  const route = routeForVoiceId(effectiveVoiceId);
  if (route === null) {
    return {
      kind: "forbidden",
      voiceId: effectiveVoiceId,
      reason: "Unknown or unsupported voiceId",
    };
  }

  if (!input.isOwner) {
    const entitled = isVoiceEntitledForKey(
      effectiveVoiceId,
      input.keyAllowedVoiceIds,
      input.keyDefaultVoiceId
    );
    if (!entitled) {
      return {
        kind: "forbidden",
        voiceId: effectiveVoiceId,
        reason: "voiceId is not entitled for this install key",
      };
    }
  }

  if (route === "elevenlabs" && !input.elevenLabsConfigured) {
    return {
      kind: "unavailable",
      voiceId: effectiveVoiceId,
      reason:
        "ElevenLabs voice requested but ElevenLabs is not configured on this worker",
    };
  }

  return { kind: "resolved", voiceId: effectiveVoiceId, route };
}

/** Trim and drop empty/whitespace-only voice ids down to undefined. */
export function normalizeVoiceId(
  voiceId: string | undefined
): string | undefined {
  if (typeof voiceId !== "string") {
    return undefined;
  }
  const trimmed = voiceId.trim();
  return trimmed.length > 0 ? trimmed : undefined;
}

/**
 * The voices a keyset key may use, for the GET /voices picker: the global Grok
 * stock voices plus any extra ids entitled to this key (ElevenLabs clones etc.),
 * with the key's default marked. Custom ids carry the id as their label since the
 * worker has no friendly name for a per-install clone.
 */
export function catalogForKey(
  allowedVoiceIds: ReadonlyArray<string> | undefined,
  defaultVoiceId: string | undefined
): VoiceCatalogEntry[] {
  const entries: VoiceCatalogEntry[] = [];
  const seen = new Set<string>();

  for (const grokVoice of GROK_STOCK_VOICES) {
    entries.push({
      id: grokVoice.id,
      label: grokVoice.label,
      provider: "grok",
      isDefault: grokVoice.id === defaultVoiceId,
    });
    seen.add(grokVoice.id);
  }

  for (const extraVoiceId of allowedVoiceIds ?? []) {
    if (seen.has(extraVoiceId)) {
      continue;
    }
    const route = routeForVoiceId(extraVoiceId);
    if (route === null) {
      continue; // never advertise an unroutable id
    }
    entries.push({
      id: extraVoiceId,
      label: extraVoiceId,
      provider: route,
      isDefault: extraVoiceId === defaultVoiceId,
    });
    seen.add(extraVoiceId);
  }

  return entries;
}

/**
 * Validate an admin-supplied entitlement selection (mint or update). Every id in
 * `allowedVoiceIds` must be a known Grok voice or an ElevenLabs-shaped id, and a
 * `defaultVoiceId` must itself be entitled (a Grok stock voice or in the allowed
 * list). Returns an error message, or null when the selection is valid.
 */
export function validateEntitlementSelection(
  allowedVoiceIds: ReadonlyArray<string> | undefined,
  defaultVoiceId: string | undefined
): string | null {
  if (allowedVoiceIds !== undefined) {
    for (const candidateVoiceId of allowedVoiceIds) {
      if (
        typeof candidateVoiceId !== "string" ||
        routeForVoiceId(candidateVoiceId) === null
      ) {
        return `Invalid voiceId in allowedVoiceIds: ${JSON.stringify(
          candidateVoiceId
        )} (must be a known Grok voice or a 20-char ElevenLabs voice id)`;
      }
    }
  }

  if (defaultVoiceId !== undefined) {
    if (routeForVoiceId(defaultVoiceId) === null) {
      return `Invalid defaultVoiceId: ${JSON.stringify(
        defaultVoiceId
      )} (must be a known Grok voice or a 20-char ElevenLabs voice id)`;
    }
    if (!isVoiceEntitledForKey(defaultVoiceId, allowedVoiceIds, undefined)) {
      return `defaultVoiceId ${JSON.stringify(
        defaultVoiceId
      )} must be a Grok stock voice or included in allowedVoiceIds`;
    }
  }

  return null;
}
