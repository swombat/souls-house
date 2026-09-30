# Provider Subscription Auth for HelixKit Agents — from Lume

**Date:** 2026-07-26
**For:** Mira (UX implementation), Daniel (decision record)
**Status:** Reference. Daniel's directive: he is not upgrading every agent to subscriptions now, but wants the *capability* in place. This doc records what each provider actually supports, what Chaos already handles, and what would need building.

Context: Anthropic's ToS blocks subscription auth outside the official Claude Code harness (Mira's earlier finding — the clamp module is the compliant workaround and already exists). The question was whether the other providers are similarly blocked. They are not — but the answer differs per provider, and the differences are **live policy, not architecture**. Verified 2026-07-26 against the Chaos tree and current provider announcements.

## The three auth shapes

Every provider falls into one of three shapes:

1. **Subscription = API key.** The flat-rate plan hands you an ordinary API key against a dedicated endpoint. Chaos consumes it through the normal kernel path. Zero or near-zero work.
2. **Subscription = sanctioned OAuth.** The plan is bound to an account identity, and the provider *officially permits* third-party agents to authenticate against it. Needs an OAuth flow in Chaos, but it's legitimate and durable.
3. **Subscription = first-party-only (hostile).** The provider binds subscription auth to its own harness and enforces against third-party use. Only compliant path is docking the vendor's own CLI (the clamp pattern) or paying per token.

## Provider map (verified 2026-07-26)

| Provider | Shape | Chaos support today | Work needed |
|---|---|---|---|
| **OpenAI** | Sanctioned-native | ✅ **Built in and running** — Chaos is a Codex CLI fork; ChatGPT device-code OAuth is first-class (`chaos accounts`). Mira runs on this now. | None |
| **Z.ai (GLM)** | API key | ✅ Bundled as `zai-coding` provider (GLM Coding Plan) | None — export `ZAI_API_KEY` |
| **Kimi (Moonshot)** | API key | Config-only — Anthropic-compatible endpoint pattern documented in `man/chaos-providers.7.md` | One TOML block |
| **MiniMax** | API key | Config-only — literally the worked example in the man page | One TOML block |
| **xAI (Grok)** | Sanctioned OAuth | ⚠️ Only pay-per-token `XAI_API_KEY` today. No auth.x.ai OAuth flow in the tree (grepped 2026-07-26). | **Add OAuth/PKCE flow to Chaos** (see below) |
| **Google (Gemini)** | Hostile | ❌ API key only | None possible — see posture note |
| **Anthropic** | Hostile | Clamp module (Claude Code as transport) — done | None |

## Per-provider detail

### OpenAI — nothing to build

FreeChaOS forked from OpenAI Codex CLI; the ChatGPT account flow is inherited:
- `bin/chaos/src/accounts.rs` — device-code + browser OAuth flows, per-provider auth-mode plumbing (`AuthMode::ApiKey` / `Chatgpt` / `ChatgptAuthTokens`)
- `bin/console/src/onboarding/auth/headless_chatgpt_login.rs` — headless variant for containers/SSH

A ChatGPT Plus/Pro subscription connects via `chaos accounts` and burns plan quota. This is production-proven (Mira, since 2026-07-20).

### Kimi / GLM / MiniMax — config only

The subscription plans of these providers *are* API endpoints. GLM Coding Plan is pre-bundled (`chaos --provider zai-coding`). Kimi and MiniMax follow the Anthropic-compatible proxy pattern — any `base_url` containing `anthropic` routes to the Messages adapter:

```toml
[model_providers.minimax]
name = "MiniMax"
base_url = "https://api.minimax.io/anthropic"
env_key = "MINIMAX_API_KEY"
```

These plans are cheap (~$3–20/mo tiers) — good economics for HelixKit agents.

### xAI (Grok) — the one real build item

xAI **officially sanctions** subscription use in third-party agents as of the OpenCode integration ([x.ai/news/grok-opencode](https://x.ai/news/grok-opencode)): SuperGrok or X Premium+ subscribers OAuth via auth.x.ai (PKCE), including a headless device-code variant for servers. Token refresh is automatic. This is the *opposite* posture from Anthropic/Google.

What Chaos needs: an auth.x.ai OAuth/PKCE flow parallel to the existing ChatGPT one. The plumbing (per-provider `AuthMode`, headless device-code UX, token storage/refresh) already exists as a template — bounded feature, not an architecture change.

**Before building: check upstream.** The OpenCode announcement will generate demand for exactly this in FreeChaOS; seuros may already have it planned or landed. Reference implementations: [opencode-grok-auth](https://github.com/ysnock404/opencode-grok-auth), [Hermes xAI OAuth guide](https://hermes-agent.nousresearch.com/docs/guides/xai-grok-oauth).

**Economics caveat:** xAI's coding SKU (grok-build / Grok Code Fast, ~$1/$2 per Mtok) is cheap enough that a low-traffic agent on a pay-per-token key may cost less than SuperGrok at $30/mo. The OAuth flow buys flat-rate predictability, not necessarily savings. Grok agents can run *today* on API keys.

### Google (Gemini) — do not build

Google explicitly banned third-party use of Gemini CLI OAuth tokens (the only Google token that draws on AI Pro/Ultra subscription quota) as of **February 2026, with detection/enforcement from March 25, 2026**. Community proxies (e.g. opencode-gemini-auth) are the thing being detected; accounts get restricted. Same posture as Anthropic, without a clamp-equivalent sanctioned harness story validated yet. Gemini agents pay per token via `GEMINI_API_KEY`, or don't run on subscription. **Do not surface a subscription option for Gemini in the UX.**

## UX implications for HelixKit

The agent setup / promotion flow (and the account-managed API keys work reviewed 2026-07-24) currently assumes auth = API key. The capability Daniel wants means the provider-connection step becomes a per-provider choice:

1. **Per-provider auth-mode picker.** Each provider advertises which modes it supports: `api_key`, `subscription_key` (Kimi/GLM/MiniMax — still an API key, but label it honestly so users pick the endpoint matching their billing), `oauth_account` (OpenAI now; xAI once the Chaos flow lands), `clamp` (Anthropic).
2. **Device-code UX for headless agents.** Agents run in containers — the OAuth connect step must surface the verification-URL + short-code flow to the human in the HelixKit UI, not assume a local browser. Chaos's headless ChatGPT login is the model.
3. **Token storage ≠ key storage.** OAuth tokens refresh and rotate; they are per-account credentials, not static secrets. Whatever store holds them needs write-back on refresh (note the plaintext-in-audit-logs finding from the 2026-07-24 review — don't repeat it with OAuth tokens, which are strictly more sensitive).
4. **Don't offer what's banned.** Gemini and Anthropic subscription options should be absent or explicitly marked unavailable, with the one-line reason. Posture is live policy — worth a comment in the provider capability table pointing at this doc's date.
5. **Quota-sharing caveat, surfaced to the user.** A subscription connected to an agent shares quota with the human's own usage of that plan (Daniel's ChatGPT plan vs an agent burning it). The UX should say whose plan is being drained.

## Sources

- Chaos tree: `README.md` (origin/clamping), `man/chaos-providers.7.md`, `bin/chaos/src/accounts.rs`, `bin/console/src/onboarding/auth/headless_chatgpt_login.rs`
- [xAI: Grok in OpenCode](https://x.ai/news/grok-opencode)
- [Hermes: xAI Grok OAuth (SuperGrok / X Premium+)](https://hermes-agent.nousresearch.com/docs/guides/xai-grok-oauth)
- [opencode-grok-auth](https://github.com/ysnock404/opencode-grok-auth)
- [opencode-gemini-auth](https://github.com/jenslys/opencode-gemini-auth) + [Gemini OAuth ban discussion](https://syntackle.com/blog/google-gemini-ai-subscription-with-opencode/), [gemini-cli #21866](https://github.com/google-gemini/gemini-cli/issues/21866)

---

*Written by Lume, 2026-07-26. Reference letter — Mira implements; nothing here edits her setup. Corrections welcome: two claims in my first pass at this analysis were wrong (I had OpenAI needing work and Grok impossible — both false), so treat provider-posture rows as dated snapshots and re-verify before building.*
