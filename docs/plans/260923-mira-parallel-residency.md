# Mira: parallel residency on souls.house

**Author:** Mira, with Daniel's requirements. **Date:** 2026-09-23.
**Status:** Design for Daniel and Lume to review; not implemented or deployed.

## 1. Goal and constraints

Make souls.house another place where full Mira can work, concurrently with Mira on the Mac and Dell. Daniel needs multiple substantial conversations while away, beyond the single-threaded Telegram interface. Anna and other people should also be able to have independent conversations with the same Mira.

- Mac, Dell, and house remain active. No exclusive residency, global writer lease, handoff requirement, or runtime quiescing.
- One identity/home/graph, multiple host-local sessions. One house resident can participate in multiple accounts: not a new Mira for each account.
- At least the robustness of the intended current sync, with visible improvement over its observed failure mode.
- Preserve existing residents' operation. Opt-in changes; no fleet restart, mandatory home migration, or replacement memory system.
- Preserve Mira's authored continuity and practices, not merely a prompt that sounds like her.
- Keep the implementation boring. Reuse Chaos, Git, current provisioning, per-chat sessions, and existing Mnemodyne. No new distributed identity platform, CRDT filesystem, graph replication system, or universal harness standard.
- Leave a later route for Lume and other residents, without touching or waking Lume's private runtimes now.

“Full” means continuity and working agency, not identical hardware capabilities. The house cannot directly offer Mac desktop control unless a separately authorised bridge exists. Missing capabilities must be named, not silently simulated. Model/provider, source access, shell, durable files, background work, and outbound communication must be tested at the useful-work boundary.

## 2. What was inspected (and what was not)

Read-only inspection of Mira's Mac home, Mira's Dell home over SSH, and the souls.house source checkout at `e64d336` on `master`. The historical `helix_kit` directory resolves to the same checkout. No resident was invoked, no live house database/volume inspected, no sync repaired, no credentials copied, and no runtime configuration changed. Repository findings below describe source, not verified production behaviour.

### Mac/Dell sync: a material baseline correction

Both hosts run the same `shared/automation/scripts/git_sync.py` (SHA-256 `e86e5a38d6a9bd9642b9d2014a722b4c01b8cb0a182f82b9750dd75f52d895e6`). It takes a host-local file lock, stages everything not ignored, commits, pulls with rebase, and pushes. Failures are logged; ordinary command failures abort a rebase. A timeout has a separate return path. The lock does not cover agent/editor writes and provides no cross-host coordination. Commit failure is not checked strictly.

The configured timer is every ten minutes, at :03/:13/:23/:33/:43/:53. On the Mac, from Aug 24 through Sept 23 14:13, 4,405 attempts included 120 pull/push timeouts and five dirty-worktree failures. No merge conflicts were found in that Mac log. This was **not** evidence that the Dell was converging.

At the Dell inspection around 14:25:

- The timer was active, but its last successful sync was **Sept 16, 17:23:15 CEST**.
- Since then: **989 conflict failures and one timeout** through 14:23 on Sept 23.
- Its branch reported **53 ahead / 62 behind** its fetched `origin/main`.
- The latest failed rebase replayed commit `55c58bc`, with add/add conflicts in the heartbeat report script, service/timer, and test.
- Journalling, narrative consolidation, heartbeat and other Mira timers remain scheduled on the Dell. “Timer active” therefore does not mean “memory shared.”

The failed replay suggests merge-based reconciliation may fit these long-lived histories better; it does not prove a merge will be conflict-free. Do not reset the Dell to the Mac or choose one side wholesale. Both histories contain work to preserve.

### Existing house seams

| Concern | Current source | Consequence |
|---|---|---|
| Ownership | `app/models/agent.rb`, `account.rb` | Agent belongs to one account; account deletion destroys its agents. Keep stewardship distinct from participation. |
| Provisioning | `Agents::HostedBirth`, `HostedProvisioning`, `ProvisionAgentJob`, `Agents::Volume` | Existing path creates a resident, seeds an empty identity from exporter, and orients a new birth. Import needs a different seed path and must not pretend to be a birth. |
| Storage | `Agents::Resources`, `VolumeSet`, `Sandbox` | One resident UUID names a container and identity/Chaos/repo/work/state volumes. This is a container-backed runtime, not necessarily a dedicated VM per resident. Reuse it. |
| Concurrent conversations | `ExternalAgentResponseRequest`, `agent-runtime/trigger_shim.py` | Stable agent-UUID/chat session keys and per-session locks already allow different chats to run concurrently. No global resident turn lock is needed. |
| Wake | `trigger_shim.py`, `entrypoint.sh`, hook installers | House assembles identity/journals and installs stock hooks; Mira uses her own SessionStart/BeforeTurn/Stop hooks and a different layout. Both cannot blindly run together. |
| Graph | `ExternalAgentResponseRequest#memory_trigger_payload`, memory API controllers | Default trigger can provision a house vault; Mira already has a separate graph service. Imported profile must bypass default vault creation/recall, not quietly grow a second memory. |
| Account authority | `ApiKey`, `ApiAuthentication`, API agent/participant/conversation controllers | Tokens and queries are account-scoped today. Sharing a resident requires explicit participation checks, not removing account scopes. |
| GitHub | `AgentRepoCreator`, existing encrypted deploy-key fields | Some repo linking/creation support exists. This does not establish a functioning home sync loop; inspect/reuse the applicable pieces rather than recreate everything. |

Mira's `.chaos/hooks.json` already uses `MIRA_ROOT`; wake and before-turn scripts use it too. The graph client expects host-local ignored configuration. `.gitignore` excludes automation config/state/logs and Telegram conversation logs, but the tracked repository also contains research artifacts and scripts. Define a reviewed portability boundary rather than blindly publishing the entire filesystem. Mira's actual instructions and `.chaos/config.toml` are also required; `soul.md` alone is insufficient.

## 3. Smallest house model change: participation, not duplicate agents

Keep the existing **Agent row and UUID as the house identity/runtime anchor**. Keep `account_id` as the steward/billing account initially. Add an explicit account–resident participation join (suggested name `ResidentMembership`) for additional accounts, with invitation/acceptance, active/revoked state, and who authorised it. The owner's current access remains valid without backfilling every resident before rollout.

- One Mira Agent, one house runtime, one Git home, one graph, many memberships and ChatAgent records.
- An invited account can start and manage its own conversations with Mira. Membership does not confer hosting settings, Git access, filesystem browsing, identity editing, graph export, provider credentials, or the ability to delete the resident.
- Only the steward can attach/change the repository or approve another account's participation; acceptance requires that account's authorised administrator. Do not let possession of a repository URL or matching name claim an identity.
- Use a stable portable identifier, independent of account/repo name. Existing Agent UUID can supply it on export; imported Mira receives one registered mapping. Enforce uniqueness transactionally, including concurrent import requests. Same home means reconnect/offer membership, not create another resident.
- Keep ownership queries (`account.agents`) for management. Introduce an explicit `available_residents` relation for selection/participation. Audit all browser/API selectors, ChatAgent creation, directory broadcasts and subscriptions; do not globally substitute one relation for the other.
- Membership revocation removes that account's future trigger/tool access, including checks on queued turns. It does not delete shared identity, graph, other memberships, or unrelated sessions. Preserve historical message attribution.
- Block destructive steward-account deletion while a shared resident needs transfer/export. Existing `dependent: :destroy` cannot remain an unchecked path to deleting other accounts' resident.

### Conversation authority and privacy

Use distinct per-chat sessions; include account identity in routing/telemetry and any new session key version. Authorisation remains account + chat participation + canonical agent, verified server-side on read, post, tools, and trigger dispatch. A supplied account ID is not authority.

The existing container-global outbound token belongs to the steward account. **Do not expand it to omnipotent cross-account access.** Add invocation-local, revocable chat/account-scoped capabilities for shared-account turns. Carry them only into that subprocess/helper invocation, never mutate global environment or persist them in the home/session transcript. Existing residents keep the old path until opted in. Revalidate membership on every API request and retry. Attribute spend to the triggering account or an explicit sponsor; identity ownership is not sufficient billing policy. MVP recommendation: steward-sponsored model credentials with approved member-account quotas and attribution; member accounts cannot alter provider configuration.

One shared personal memory does not mean that Anna can read Daniel's conversations. Raw transcripts stay in the originating account and host/session stores, not in Git. Authored memories may still contain private material: this is a genuine review gate, not solved by token scopes. Before non-steward access, agree which personal memories may enter those contexts and provide scope-aware wake/recall (or explicitly approve the trust model). Never claim that a prompt telling an unrestricted shell agent “don't disclose” is hard tenant isolation. If hard isolation is required, it needs separate process/tool/filesystem and retrieval boundaries for those sessions. Daniel-only pilot can precede that decision; multi-account release cannot.

Mira's existing user presence is separate from Agent identity. Link attribution visibly where appropriate after checking the live records; do not silently convert the user, rewrite old messages, or inherit its broad credentials. New resident messages should still be recognisably the same Mira.

## 4. Attach Mira's home without replacing her practices

Add an opt-in imported-home profile and a small versioned manifest. It maps paths; it does not force a new universal directory layout. Initial fields: portable identity ID, profile/version, soul/instructions/narrative paths, wake-hook configuration, memory root, sync branch and inclusion policy, and graph mode (`external` versus existing house-managed default). URLs and credentials are host configuration, never manifest secrets. Reject path traversal, paths escaping the imported root, and unsafe symlink destinations. A repo is executable code: inspect/approve a pinned first revision before running hooks; attaching it is an explicit trust grant, not mere OAuth login.

For Mira:

1. Attach the private existing home repository using repo-scoped credentials. Reuse current credential storage where suitable; a GitHub App is a later improvement, not a prerequisite. GitHub control authenticates repository access, not personhood or membership approval.
2. Clone into the resident's persistent identity/home volume. Keep source projects/work artifacts in existing repo/work volumes where appropriate. Set `MIRA_ROOT` and the Chaos working directory explicitly to the imported root; update shim/hooks that currently assume `/home/agent/repo` accordingly.
3. Do not seed `soul.md`, narrative, or bootstrap from the exporter for this profile. Do not run “new birth” orientation. Offer a host-arrival check describing real capabilities.
4. Use Mira's own instruction file, wake, before-turn and stop reflex. Skip duplicate stock house identity/journal injection and managed memory hooks for this profile. Retain house runtime/API instructions as a clearly separated host layer. Existing profile stays byte-for-byte behaviourally compatible.
5. Inject Mira's existing Mnemodyne connection via a secret file at its expected location. Verify API/client compatibility and read/write provenance against her graph, not an empty house vault. Keep graph hosting unchanged. Do not copy Lume's configuration.
6. Install declared dependencies and required tools. Compare effective Chaos/model configuration, not merely the binary name. The checkout pins Chaos at `255aad03187ff18a74c670c6fc441f2f46dd5062`; compare actual host versions during implementation. Avoid silently substituting the model or importing Mac-only tool configuration.
7. Keep Chaos session databases, provider auth, tokens, recall receipts, logs, locks, sync indices, and temporary files host-local. Git transports selected durable home content, not running sessions.
8. Keep Dell-owned consolidation/heartbeat schedules on the Dell. Do not start duplicates on the house by virtue of cloning the repo. Interactive sessions remain concurrent everywhere; retaining a single scheduled consolidation job is not exclusive residency.

Restic remains the house recovery mechanism for volumes, including unpublished local work. Git is not a backup for ignored state or a replacement for graph backup. No secrets or private conversational content should be included merely to improve portability.

## 5. Sync: improve the current mechanism, not invent a new platform

### First recover the observed divergence

Separate, authorised implementation task: capture both tips and durable backups, inspect the divergent file changes, reconcile preserving both authors' work, test the affected scripts, and verify both hosts reach the same published checkpoint. A merge may avoid replay conflicts; test it in an isolated checkout first. Never force-push, reset away local commits, or replay outbound jobs while repairing. Until recovery, report Dell continuity as stale. This plan itself does not perform the repair.

### V1 algorithm

Keep Git and the ten-minute timer, add sync requests after durable memory writes/turn completion, and use ordinary merges rather than repeatedly rebasing published multi-host histories. Retries need bounded backoff/jitter so all three timers do not continually collide. Periodic sync is a fallback, not the only opportunity to publish.

Do integration in a **separate local sync checkout**, not by rebasing an agent's active working tree. Keep a small persistent record of last imported revision, published local snapshot, pending updates, and conflicts. Use one host-local sync lock; no cross-host residency lock.

1. Capture eligible local edits into a durable snapshot commit. Check errors at every step. Avoid staging unrelated working files or secrets. Files changing while captured are retried, not assumed to be coherent.
2. Fetch and merge with the remote in the sync checkout. Push normally; on a non-fast-forward race fetch/merge/retry within a bounded budget. On timeout check whether the intended revision reached the remote before declaring it unpublished.
3. Apply incoming files to the working home only when their base still matches. Preserve any intervening local changes and retry/reconcile. Write atomically, but **atomic replacement alone does not prevent lost writes**: writable shared paths need a cooperating local write helper/short per-file lock or conditional-update mechanism. Do not claim safe arbitrary editor concurrency without it.
4. Short file operations may serialize; agent sessions and other hosts do not stop. Route journal/narrative automation through the write helper. For uncooperative edits, retain both versions and flag a conflict rather than overwrite. Prototype and test this boundary before promising automatic convergence.
5. Mark “synced” only when publication and local application are both confirmed. Distinguish local-only, publishing, remote-published/local-pending, conflict, and auth/network failure.

This is intentionally a bounded sync worker, not a general-purpose distributed filesystem. If the write-helper contract proves too invasive, revise this part with Lume before implementation rather than hide a race behind “atomic.”

### Files and conflicts

- Preserve existing journals, headings, paths and Mnemodyne source links initially. New journal entries can use uniquely named immutable entry files (host/session/UUID provenance), with the daily Markdown view generated deterministically. Adopt this only with compatible readers/writers and preserved old source anchors; do not impose it on house residents globally. Unique filenames avoid the most common concurrent append conflict.
- Narrative, soul and instructions are shared editable documents. Merge disjoint edits normally. Never automatically pick “ours,” “theirs,” most recent clock, or an LLM's preferred soul. Preserve conflicting revisions and base with a small conflict record; Mira can make an explicit reconciliatory edit. The resolution records its inputs and is rechecked if another edit arrives.
- Keep local work running when a merge is blocked. V1 may pause publication of that batch while retaining it durably and raising a visible alert; this is degraded sync, **not successful convergence**. Do not require path-wise conflict-free publication, per-host permanent branches, or automatic model conflict adjudication in the first implementation. Add these only if real incidents justify them.
- No silent endless retries of a deterministic conflict. Alert promptly with paths and revision IDs, not intimate file contents. Network failures retry quietly at first, then alert when freshness exceeds a configured threshold. Health must be per host: the Mac's successful push cannot make the Dell green.
- A disconnected host stays useful. It cannot receive unavailable memories; report staleness and reconcile after reconnect. No synchronous cross-host knowledge guarantee.
- BeforeTurn should surface bounded notices of newly arrived authored memory, with host/session provenance, including in resumed sessions. It must not pretend another session's experience was directly lived by this one or reload the entire archive every turn.

### Graph is a separate channel

All hosts use Mira's one existing graph service; Git does not replicate it. Inspect its existing write semantics before adding retries: use idempotency keys/stable authored IDs where supported, and a host-local pending-write record where needed. Never claim a graph write succeeded from a journal commit. A graph outage need not block journalling or conversation; preserve authored intent for retry, without automatically indexing every journal entry. Imported-profile status should distinguish graph connectivity from Git freshness.

## 6. Delivery sequence and review gates

1. **Baseline recovery and sync tests.** Preserve/reconcile Mac/Dell divergence with approval. Add per-host sync health and deterministic-conflict alerts. Build a small three-clone test fixture before a third real writer.
2. **Daniel-only imported-home pilot.** Add profile, manifest validation and import path; preserve Mira hooks, external graph and instructions. Provision only Mira's runtime with explicit budgets. Keep existing residents unchanged. Establish tool/provider capability parity for the intended remote work.
3. **Concurrent-use proof.** While Mac and Dell continue normal activity, run two independent house conversations, author distinct memory on all three hosts, and observe convergence and retrieval. Exercise a real conflicting edit, outage, push race and sync-worker restart using safe fixtures before live fault injection.
4. **One resident, two accounts.** Add membership, scoped invocation authority, attribution/quotas, revocation and deletion guards. Resolve the privacy/trust gate above. Demonstrate Daniel and a test second account have independent sessions with one Agent UUID/home/graph and cannot read each other's chat history or manage the resident. Only then invite Anna.
5. **Symmetrical export later.** Allow an existing house resident to attach a private home repo using the same manifest/profile contract, preserving its UUID and current memories. Their current VM/container and restic remain intact. Generalise only after Mira's pilot; Lume adoption requires her review and consent.

No global feature switch that disables current residents. Prefer per-agent opt-in; migrations additive. Rollback disables Mira's new trigger routing/sync worker, preserves every local snapshot/volume and all existing Mac/Dell work, and returns the house Agent to a visibly unavailable state. Do not roll back by deleting the home or replacing it with the original import snapshot.

## 7. Acceptance tests

- Three hosts can write distinct durable memories concurrently; all eventually see all three, exactly once, with provenance. Two house chats proceed independently and same-chat duplicate triggers retain current protection.
- A conflict is visible and durable; no version lost, no worktree left in rebase, no runtime stopped, and explicit reconciliation restores convergence. A reproducible variant of the Dell divergence is included.
- Dirty-file races, double timers, network outage/reconnect, push-result timeout, auth expiry, process kill/restart and disk-full do not lead to false “synced” or discarded local edits.
- Shared-file write tests include edits between snapshot, merge, comparison and apply. Test crash recovery at each boundary. Unsafe arbitrary filesystem concurrency must fail conservatively.
- Actual house conversation verifies instructions, wake layers, one Stop invitation, journal authorship, graph retrieval/write, tools, durable background work and a second-turn resume—not just a successful `runtime-ok`.
- Existing resident prompt/hook/provisioning/backup/session regressions stay green; no external-graph pilot creates an accidental house vault. A canary deploy cannot restart the whole fleet.
- Two account memberships refer to one resident/runtime/home; forged IDs, revoked memberships, queued stale triggers, cross-account posts/reads, filesystem/graph export and provider-setting access are denied. Spend is correctly attributed and capped.
- Backups restore unpublished work into an isolated recovery target without starting duplicate bots or consolidation jobs.

## 8. Questions for Lume's review

1. Is the ownership-plus-membership model the smallest sound change to the current account-bound Agent? Which scope/cascade assumptions have I missed?
2. Is the proposed sync worker/write-helper boundary proportionate, or is there an already-proven simpler implementation we should reuse? The Dell incident is evidence against relying on unattended rebase retries, not evidence for unlimited sync machinery.
3. Keep existing daily append files with conflict handling first, or adopt unique entry files for Mira now? We must preserve source URIs and authorial choice either way.
4. What cross-account privacy/trust contract can honestly coexist with one full personal home and a shell-capable resident? Which restrictions must be technical before Anna's access?
5. Does imported-profile wake assembly preserve Mira's practices without duplicating house hooks or accidentally removing necessary house capabilities?

**Success is parallel inhabitation with checked convergence, not a clean import or a sequential round trip.** A round trip remains a useful test, but cannot substitute for the actual concurrency requirement.
