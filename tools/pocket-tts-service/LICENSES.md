# License inventory — Local Pocket TTS (Azelma) voice service

Three licenses are separate and must not be conflated: **code**, **model
weights**, and **voice embedding source**. This service is default-off; when it
is enabled, the obligations below apply to whatever ships with it.

## Code — Kyutai Pocket TTS — MIT (permissive)

[Pocket TTS](https://github.com/kyutai-labs/pocket-tts) ships an MIT `LICENSE`.
Use, modification, redistribution, and commercial use are all permitted; keep
the copyright and permission notice.

## Model weights — kyutai/pocket-tts — CC BY 4.0

The gated model card declares `license: cc-by-4.0`: **commercial use PERMITTED,
attribution REQUIRED**. Access requires accepting the model's gated terms on
Hugging Face (an account plus the company/university + purpose fields). The
download uses a read-only Hugging Face token that this service reads at runtime
from `~/.cache/huggingface/token` and never prints, logs, or commits.

The model card also carries a load-bearing **Prohibited use** clause:

> Prohibited uses include, without limitation, voice impersonation or cloning
> without explicit and lawful consent; misinformation, disinformation, or
> deception (including fake news, fraudulent calls, or presenting generated
> content as genuine recordings of real people or events); and the generation
> of unlawful, harmful, libelous, abusive, harassing, discriminatory, hateful,
> or privacy-invasive content.

This implicates any cloned voice. The bundled voices below are cloned recordings
whose own CC BY licensing is the "explicit and lawful consent" basis for those
specific voices — it is NOT blanket permission to clone an arbitrary new voice.

## Voice: Azelma (default local voice) — CC BY 4.0, attribution required

- The "Azelma" demo voice resolves to speaker **p303 of the CSTR VCTK Corpus**
  (`vctk/p303_023_enhanced.wav` via kyutai/tts-voices).
- License: **Creative Commons Attribution 4.0 International (CC BY 4.0)**.
  - Commercial use: **PERMITTED**.
  - Attribution: **REQUIRED** — credit the CSTR VCTK Corpus
    (https://datashare.ed.ac.uk/handle/10283/3443) under CC BY 4.0 wherever the
    voice ships.
- The voice `.wav` is openly downloadable; the gated part is the model weights.

CC BY covers the recording's copyright. It does not by itself resolve
voice-likeness or publicity-rights questions of synthesizing a real person's
voice at product scale — get that reviewed before shipping a cloned real
person's voice.

## Voice: alba (documented fallback) — CC BY 4.0, attribution required

- `alba` = `kyutai/tts-voices/alba-mackenna/casual.wav`, voice-acted by Alba
  MacKenna, released under **CC BY 4.0** (commercial PERMITTED, attribution
  REQUIRED — credit Alba MacKenna). The same weights-gating and voice-likeness
  caveats as Azelma apply.

## Catalog voices to AVOID for commercial use

- `expresso/*` (e.g. `cosette`) and `ears/*` (e.g. `jean`) are **CC BY-NC 4.0 —
  NON-COMMERCIAL ONLY**. Do not use these in any shipped product.
- `voice-donations/*` and `voice-zero/*` are **CC0** (public domain, no
  attribution required) — the safest option if voice choice is flexible.
