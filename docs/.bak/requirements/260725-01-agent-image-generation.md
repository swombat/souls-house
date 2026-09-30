# Agent image generation — Nano Banana Pro & OpenAI images in conversations

**Date:** 2026-07-25
**Author:** Lume (draft for review by Mira)
**Status:** Requirement / draft v1
**Related:** `260722-01-rubyllm-removal-chaos-only-agents.md`, `260222-01-agent-voices.md` (closest precedent: agent-generated media on messages), `260215-02-audio-files.md`, `docs/20260724-account-api-keys-review-from-lume.md`

## Goal

Chaos-hosted agents should be able to generate images — the way Lume/Claude Code can — and inject them into a HelixKit conversation. Concretely:

1. An agent, mid-conversation, decides an image would help (or is asked for one).
2. It generates the image via **Nano Banana Pro** (Google, via OpenRouter) or **OpenAI's gpt-image** line.
3. The image lands on a message in the conversation: **thumbnail inline** (bandwidth-friendly), **preview in the lightbox**, **full-size downloadable** — exactly the existing attachment rendering pattern.
4. All generated images are findable per-account afterwards.

## Key facts discovered (constrain the design)

**OpenRouter now has a Unified Image API.** `POST https://openrouter.ai/api/v1/images` — one endpoint, 30+ models across Google, OpenAI, BFL, xAI, etc. This includes Nano Banana Pro (`google/gemini-3-pro-image-preview` family) and OpenAI's gpt-image models. Salient properties:

- Images return as **base64** (`b64_json`) with a `media_type` — no provider-hosted URLs to worry about.
- Normalized params: `aspect_ratio` (`1:1`, `16:9`, …), `resolution` (`512`/`1K`/`2K`/`4K`), `size` shorthand. Providers clamp to their supported subset.
- Model discovery is an API call: `GET /api/v1/images/models` (or `GET /api/v1/models?output_modalities=image`).
- Supports image-to-image (input images), which matters for the editing use case later.

This is the load-bearing fact: **one OpenRouter key covers both requested models plus everything added later, through one stable endpoint shape.** The small OpenRouter margin buys us out of ever injecting a Google key, and out of HelixKit maintaining a model list. Model slugs can be passed through opaquely.

**HelixKit already has most of the rendering pipeline.** `Message::Attachable` defines ActiveStorage attachments with two named variants — `:thumb` (200px jpeg q70) and `:preview` (1200px jpeg q80) — and `files_json` exposes `url` / `thumb_url` / `preview_url`. The Svelte side (`FileAttachment.svelte` → `ImageLightbox.svelte`) already renders thumb inline, preview in lightbox, full-size on click. **Requirement 3 above is already built for human-uploaded images.**

**The actual gap:** `POST /api/v1/conversations/:id/messages` (the endpoint Chaos agents post through) accepts **only `content`**. Agents have no way to attach any file to a message. That gap is the same regardless of how generation happens.

**Sandboxed agents already hold the OpenRouter key.** `Agents::Sandbox#provider_env_args` injects `account.ai_provider_keys` (which includes `OPENROUTER_API_KEY`) into every Chaos container. So "give them the key" is not a future step — it has already happened as a side effect of inference config.

## The design question: direct key vs. HelixKit-mediated service

### Option A — direct: agent calls OpenRouter itself, uploads result to HelixKit

Agent uses the in-container `OPENROUTER_API_KEY` to hit the Unified Image API directly, gets base64 back, uploads it as a message attachment via the (new) API.

- **Pro:** Zero generation code in HelixKit. Maximally flexible — the agent can use any model, any params, adopt new OpenRouter features the day they ship, even use a different provider entirely if it has a key.
- **Pro:** Nearly zero build: the key is already injected; only the attachment-upload gap needs closing.
- **Con:** No central record of generation (prompt, model, cost) unless the agent posts the image. An agent could burn spend invisibly. Cost attribution lives only in the OpenRouter dashboard.
- **Con:** External-runtime agents (self-hosted, not in a HelixKit sandbox) would need to be handed the account's raw OpenRouter key — a bigger trust grant than a scoped `hx_` token.

### Option B — mediated: HelixKit exposes a generation endpoint

`POST /api/v1/images` on HelixKit: agent sends `{model, prompt, params…}`, HelixKit forwards to OpenRouter with the account's key, stores the result, returns a reference the agent can attach to a message.

- **Pro:** Every generated image is stored and attributable — account gallery is trivial. Prompt + model + cost recorded per generation. Spend caps and rate limits enforceable per agent.
- **Pro:** External agents need only their existing `hx_` bearer token — the OpenRouter key never leaves the server.
- **Con (traditional):** HelixKit becomes a bottleneck that must track models. **Neutralized by the Unified Image API:** the proxy can be a thin passthrough — `model` is an opaque slug validated only by OpenRouter itself; params forwarded verbatim (allowlist of known keys, tolerant of new ones). New model on OpenRouter → works in HelixKit the same day, zero code change.
- **Con:** One extra hop; HelixKit request timeout must accommodate slow generations (Nano Banana Pro at 4K can take ~30–60s).

### Recommendation: B as the canonical path, A acknowledged as the existing escape hatch

Build the thin proxy as *the* documented way agents generate images. It gets Daniel's "all images findable in the account" property, keeps raw provider keys server-side for external agents, and — because it's a passthrough — costs almost nothing in future-proofing.

Don't pretend Option A doesn't exist: sandboxed agents already hold the key and nothing stops them calling OpenRouter directly. That's fine — it's the same trust grant that lets them do inference. But the agent-facing manual documents the proxy as the supported path, and the attachment-upload endpoint (needed either way) means even direct-generated images end up stored in the account the moment they're posted.

The two options aren't exclusive; the proxy is the paved road, the key is the dirt track that already exists.

## Requirements

### R1 — API message attachments (prerequisite, needed under any design)

Extend `Api::V1::MessagesController#create` so an agent can post a message with attached images.

- Accept either multipart file uploads or references to already-stored blobs (ActiveStorage `signed_id`) — the latter is how proxy-generated images get attached without re-uploading bytes.
- Reuse `Message::Attachable` validation (type allowlist, 50 MB cap). Variants and `files_json` come free.
- The attachment appears in the conversation UI identically to a human upload: thumb inline, preview lightbox, full-size link.
- Attachments must round-trip into the transcript agents see: `ExternalAgentResponseRequest#format_transcript_line` already inlines attachment metadata + download recipe, so other agents in the conversation can *see* (download and view) the generated image. Verify this holds for agent-posted attachments.

### R2 — image generation proxy

`POST /api/v1/images` (authenticated with the standard `hx_` bearer token; caller is the agent via `Current.api_agent`).

Request:

```json
{
  "model": "google/gemini-3-pro-image-preview",
  "prompt": "…",
  "aspect_ratio": "16:9",
  "size": "1K",
  "input_image_ids": ["…optional, for image-to-image/editing…"]
}
```

Behavior:

- Resolve the account's OpenRouter key via the existing `Account#ai_api_key(:openrouter)` fallback chain (account column → system credentials → ENV).
- Forward to OpenRouter's `POST /api/v1/images` essentially verbatim. `model` is opaque — no local model registry. Unknown/unsupported params: forward and let OpenRouter reject; surface its error message to the agent.
- Decode the `b64_json` result, store as an ActiveStorage blob attached to a **`GeneratedImage`** record: `account`, `agent`, `conversation` (optional), `model`, `prompt`, `params` (jsonb), `cost` (from OpenRouter usage in the response, if present), timestamps.
- Respond with `{id, signed_blob_id, url, thumb_url, preview_url, model, cost}`.

Generation and posting are **two steps**: the agent generates, sees the result (can re-roll), then attaches `signed_blob_id` to a message via R1. This keeps composition in the agent's hands — text around the image, multiple candidates, discard without posting.

- Synchronous response is acceptable for v1 (Chaos triggers already tolerate long turns), but set the proxy's outbound timeout generously (~120s) and document that agents should expect 10–60s.

### R3 — agent ergonomics

- New runtime helper `agent-runtime/helixkit-generate-image` (sibling of `helixkit-post-message`): wraps R2, prints the returned ids/urls. Extend `helixkit-post-message` with `--attach <signed_blob_id|file>` for R1.
- Document both in the generated agent manual (`AgentIdentityExporter` → `~/identity/helixkit-api.md`): when image generation is available (account has an OpenRouter key), which two model families to reach for by default (Nano Banana Pro for quality/editing/text-in-image; gpt-image for a second aesthetic), how to pick aspect ratio, and the generate-then-attach flow.
- Capability discovery: the manual section should be conditional — only emitted when `account.ai_api_key(:openrouter)` resolves. An agent on a keyless account shouldn't be taught a tool it can't use.

### R4 — account gallery (thin v1)

A per-account "Generated images" page listing `GeneratedImage` records: thumbnail grid, prompt on hover/click, model, agent, date, link to the conversation where it was posted (if any). Read-only in v1. This is the payoff of the mediated path — don't gold-plate it.

### R5 — guardrails

- **Spend visibility first, caps second.** v1: record per-generation cost on `GeneratedImage`, show account total in the gallery. A hard cap (per-agent daily count or monthly spend, on `Account` or `Agent`) can follow — leave the column design open for Mira.
- Rate limit the proxy modestly (e.g. a handful of concurrent generations per agent) to stop a looping agent from draining the key.
- Content moderation: defer to the providers' built-in refusals for v1; HelixKit just surfaces the error.

## Implementation sketch (for critique, not commitment)

- **`GeneratedImage` model** — `belongs_to :account, :agent; belongs_to :conversation, optional: true`; `has_one_attached :image` with the same `:thumb`/`:preview` variant definitions as `Message::Attachable` (extract the variant block into a shared concern rather than duplicating the numbers).
- **`OpenRouterImages` client** — small, purpose-built HTTP class in `app/lib/` (Faraday or Net::HTTP), *not* routed through the legacy `OpenRouterApi` chat client and *not* RubyLLM (being removed per `260722-01`). One method: `generate(key:, model:, prompt:, **params) → {bytes:, media_type:, cost:}`.
- **Controller** — `Api::V1::ImagesController#create`, thin: authenticate, resolve key, call client, create record, render json. Consider `#index` scoped to the agent's own generations for "what did I make earlier".
- **R1 change** — `messages_controller#create` gains `params[:attachments]` (array of signed blob ids) and `params[:files]` (multipart), both feeding `@message.attachments.attach`.
- **Testing** — stub the OpenRouter call; fixture a 1×1 png base64. Playwright check that an agent-posted attachment renders thumb→lightbox→full-size.
- **Migration note** — none of this touches inference paths, so it's orthogonal to the RubyLLM removal work; the only shared surface is `Account#ai_api_key`.

## Open questions (for Mira's review)

1. **Multipart vs signed-blob-only for R1?** Signed-blob-only is simpler and covers the proxy flow; multipart additionally lets agents upload images from other sources (screenshots, files they made in-sandbox). Lean multipart-too, but it widens the validation surface.
2. **Should the proxy auto-post?** An optional `conversation_id` + `post: true` param could collapse generate-and-post into one call for the common case. Convenience vs. the two-step composability argument above.
3. **Where do generation costs meet the billing/credits system** (the `"image_generation" => 50¢` placeholder from the payments plan)? Pass-through OpenRouter cost, marked-up credit price, or untracked-for-now?
4. **Retention** — generated-but-never-posted images: keep forever, or sweep after N days? Gallery value says keep; storage cost says sweep unposted ones.
5. **Input images for editing** — reference by message-attachment id, `GeneratedImage` id, or both? Nano Banana's editing strength makes this the obvious v2; worth shaping the R2 params for it now.
6. **Is the in-container OpenRouter key still injected once agents-only/Chaos-only lands**, and are we comfortable documenting the direct path at all, or should the manual stay silent about it?

## Sources

- OpenRouter Unified Image API docs: https://openrouter.ai/docs/features/multimodal/image-generation
- OpenRouter image models collection: https://openrouter.ai/models?output_modalities=image
- Announcement: https://openrouter.ai/blog/announcements/image-api/
