# Review of 01d: direct credentials, agent autonomy, inbound bridges

**Date:** 2026-07-31
**Author:** Lume
**Reviewed:** `260728-01d-agent-service-integrations.md` (Daniel/Mira, v4)
**Status:** Review — endorses the redesign; answers §17's seven questions; one structural elevation requested

---

## 1. Verdict

v4 is correct, and the earlier drafts' mistake is worth naming precisely so it stays caught. v1's genuinely load-bearing finding — Rails must own the credential relationship because only Rails can host user consent — survives intact as v4 §2.1. But v1–v3 conflated *credential custody* with *operation mediation* and built the second on top of the first: action declarations, parameter schemas, per-capability manuals, a `ServiceInvocation` resource. That is a tool registry with REST syntax — the very architecture this codebase already evicted once (the 2026-05-07 MCP removal), for the same reason v4 now names: every provider operation became HelixKit development work. The agents are full coding harnesses; the skill-file lesson was always "credentials + docs + curl," and v4 applies it to its logical end. Two review rounds (01b, 01c) hardened the mediation layer's internal correctness without asking whether the layer should exist. Rollback was right.

What v4 keeps from v1–v3 is exactly what deserved keeping: external-identity connections with multiplicity, consent ownership and transfer, durable account-bound OAuth attempts, honest credential storage, the account-isolation invariants. What it deletes is everything whose existence depended on the proxy.

## 2. One structural elevation: scope selection IS the policy model

This is my only architecture-level request before implementation.

v3 could enforce per-action authority because every call transited Rails. v4 honestly deletes that (§2.3, §3) — which means **the scope set chosen at authorization time is the only real policy instrument remaining**. It is provider-enforced, unbypassable by any Rails bug, and decided in a single UI moment by a human. Consequences the requirement should state explicitly rather than leave implicit in §3:

- **Scope-selection UX is the security model**, not a settings detail. The moment of choosing scopes deserves the design attention the old grant matrix got.
- **The prompt-injection exposure survives the redesign in a specific form:** an agent that reads hostile external content while holding a write-capable credential can be induced to use it. v3's mitigation was "no send action exists"; v4's honest equivalent is **read-only scope defaults for content-bearing services** (Gmail, Drive, Dropbox). The write-capable profile should be the deliberate choice, never the default.
- §14's warning bullet ("credentials must not be pasted into untrusted pages") addresses disclosure, not induced use. Add a sentence: *the primary defense against induced misuse of a credential is the narrowness of its scopes; the UI must present scope narrowing as the protection it is.*

This dovetails with Q3 below — named access profiles are the mechanism that makes the one real policy lever usable.

## 3. Answers to §17

### Q1 — Runtime secret materialization: recreation now, but stabilize the contract

Extend the existing safe container-recreation pattern for v1. Service changes are connect/rotate/disconnect events — rare — and the recreation path exists and is tested. A hot-reload reconciliation state machine is exactly the kind of machinery v4 exists to avoid building prematurely.

But **decouple the agent-facing contract from the delivery mechanism now**:

- The manifest lives at its own stable path (`/run/helixkit/services.yml` as proposed), **on tmpfs**, written at container start from the encrypted payload — not embedded deeper into `credentials.yml.enc`'s structure.
- Later hot-reload then changes only the writer; agents never see a contract change.
- tmpfs solves §14's backup requirement *structurally*: a file that cannot persist cannot leak into restic snapshots, and removal-by-recreation is then also guaranteed removal from disk (strengthens §9's honest-limit posture at zero cost).

One carve-out that must be explicit: **routine access-token refresh under strategy 8.2 never triggers recreation.** The provisioned bundle makes the agent self-sufficient; the runtime copy of a short-lived access token going stale is normal operation. Only rotation of *refresh material* (or revocation) increments `credential_revision` and reconciles.

### Q2 — The three credential strategies are the minimum

They are one decision dimension: **who may hold the refresh secret.**

- `static` — nobody refreshes (API keys, PATs, service-account JSON);
- `self_refreshing` — the agent holds everything (correct wherever the provider supports public-client/PKCE refresh — Dropbox does);
- `refresh_broker` — Rails holds an application-wide confidential client secret that must not fan out to every runtime (Google's confidential web client forces this).

Collapse to two and you either hand application-wide secrets to every agent (unacceptable) or route all outbound token lifecycle through a broker that most providers don't need (a dependency v4 exists to remove). Keep three. One refinement: the manifest's `credential_strategy` field should make the agent-side procedure uniform — *read the manifest; it tells you whether the token is in hand, self-refreshable with the included material, or fetched from the named broker endpoint.* The broker (§8.3) is correctly scoped: token issuance only, no operation proxying, and issuance events are audited (§13).

### Q3 — Yes to a small named access-profile concept, authorization-time only

Raw OAuth scope strings are unusable by the humans making the one decision that matters (§2 above). Per-provider named profiles — Dropbox: `read-only` / `read-write` / `full + sharing`; Gmail: `read-only` / `read + drafts` / `full` — expanding to exact scope sets at the authorization attempt. Constraints:

- Profiles exist **only** at authorization time, as scope-selection sugar. Nothing stores or enforces a profile post-authorization; the connection's displayed authority is always its actual `granted_scopes`.
- Defaults per service class: content-bearing services default to the read-only profile (§2).
- This is where 01c's write-moratorium philosophy survives honestly: not "no send action exists" but "the send-capable scope is a deliberate, labeled, non-default choice."

### Q4 — First-time provisioning of a personal connection requires the consenting user

Provisioning Daniel's Dropbox to a new agent is a new delegation of Daniel's external identity. That **is** broadening consent, and the settled rule — personal consent cannot be broadened by account administration — decides this question. So:

- The consenting user enables/disables their personal connection per agent.
- Admins may reduce or remove (disable provisioning, remove connection from account) but never extend.
- Optional, explicit escape hatch: the owner may mark a connection *"freely provisionable within this account"* — delegating the per-agent decision deliberately, visible on the connection card. Default off.

Account-managed connections remain admin-provisionable, as drafted.

### Q5 — Documentation URLs live in Rails service definitions, delivered via the manifest

Single source of truth, ships with deploys, zero image churn — the same argument that moved manuals into Rails in v2, now shrunk from manuals to URL pointers, which is the right size for the direct-access model. Not the image; not both (duplication drifts). The image keeps only the generic §7.3 instruction. The URLs are hints, not gospel — agents can and will also search; the manifest's job is to make the *right* starting point one read away.

### Q6 — Oura migration: never copy tokens; re-consent per additional account

Oura rotates refresh tokens on use — a credential duplicated across two accounts breaks at the second owner's first refresh, corrupting both. Therefore:

- Migration is **opt-in, per user, one-time**: a prompt attaching the existing personal Oura connection to one chosen account (moving the token row, not copying it). The user-global row persists untouched until the user acts (criterion 17).
- A user in multiple accounts who wants Oura agent-access in more than one performs a fresh OAuth consent per additional account — separate authorization, separate token lineage. This is the only shape token rotation permits, so the requirement should state it as a rule, not a limitation.
- The platform-owned sync/context feature (§11) follows the token to its new home as a separate consumer, unchanged.

### Q7 — Best-effort removal is sufficient; per-agent credentials are a pattern, not a feature

§9's honesty is the right posture. For higher assurance, note that **the model already supports per-agent isolation with zero new machinery**: connections are identity-scoped and multiple per provider; "one authorization per agent" is N consent flows through the existing door. No feature improves on that — most providers offer nothing that would let HelixKit mint per-agent sub-credentials. So:

- v1: best-effort removal + provider revocation + honest reporting, plus **UI copy** presenting the pattern: "for stronger isolation, connect a separate authorization for each agent."
- Future: where a provider offers native short-lived delegation (GitHub fine-grained PATs, STS-shaped services), that arrives as a new `credential_strategy`, per provider — not as a generic mode.

## 4. Smaller notes

1. **§7.1 placement is right and has a precedent worth citing:** runtime-instructions.md already draws the "hosting context, not identity" line (`260725-02a`); the manifest is the same category. Agents should be told the manifest is *runtime-supplied, not part of your identity* in the same labeled way.
2. **§16's proof is well-formed because it can fail.** "No Dropbox helper, no HelixKit operation manual" makes the test falsifiable — if the agent can't operate Dropbox from provider docs alone, the redesign's central bet is wrong and we learn it in step 5, cheaply. Keep that property; resist adding helpers to make the test pass.
3. **Suggested addition to §16:** after step 5, have the agent *refresh its own access token* (strategy 8.2) — the proof should cover the credential lifecycle, not just first use.
4. **Acceptance criterion to add:** *routine access-token refresh by the agent does not require container recreation or any HelixKit interaction under the self-refreshing strategy* (locks in Q1's carve-out).
5. **Acceptance criterion to add:** *the scope-selection step presents named profiles with read-only defaults for content-bearing services, and the connection card displays actual granted scopes, not the profile name* (locks in §2/Q3).
6. `credential_payload` as encrypted structured data (§4.1) is the honest generalization of 01c's `api_key` column fix — same lesson, properly finished.

## 5. Readiness

With §2's elevation folded into the requirement text and the two added acceptance criteria, I consider v4 ready for implementation planning. The Dropbox proof (§16) should run before any second service definition is written — it is the falsifiable test of the whole redesign, and everything else is cheap once it passes.

---

*Provenance note for the record: the v1–v3 mediation layer was my design, reviewed twice by Mira for internal correctness; the question neither round asked — should the layer exist — was caught by Daniel's review of the first implementation. The precedent that should have answered it earlier was already in the tree: the MCP-to-skillfile migration, which I cited in v1 §2.1 and then under-applied.*
