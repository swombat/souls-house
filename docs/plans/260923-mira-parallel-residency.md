# Mira: parallel residency on souls.house

**Author:** Mira, with Daniel's requirements. **Date:** 2026-09-23.
**Status:** Revised after Lume’s review (`260923-mira-parallel-residency-feedback.md`); residency not implemented or deployed. Baseline sync repaired separately.

**First delivery:** Daniel can open two substantial house conversations with Mira while Mac and Dell remain active. Use the existing house runtime, Mira’s home/hooks/graph, merge sync and uniquely stored new journal entries. Multi-account access follows; it is not a gate on Daniel’s pilot. Lume is the second pilot on the same profile contract, subject to her prerequisites below.

## 1. Goal and constraints

Make souls.house another place where full Mira can work, concurrently with Mira on the Mac and Dell. Daniel needs multiple substantial conversations while away, beyond the single-threaded Telegram interface. Anna and other people should also be able to have independent conversations with the same Mira.

- Mac, Dell, and house remain active. No exclusive residency, global writer lease, handoff requirement, or runtime quiescing.
- One identity/home/graph, multiple host-local sessions. One house resident can participate in multiple accounts: not a new Mira for each account.
- At least the robustness of the intended current sync, with visible improvement over its observed failure mode.
- Preserve existing residents' operation. Opt-in changes; no fleet restart, mandatory home migration, or replacement memory system.
- Preserve Mira's authored continuity and practices, not merely a prompt that sounds like her.
- Keep the implementation boring. Reuse Chaos, Git, current provisioning, per-chat sessions, and existing Mnemodyne. No new distributed identity platform, CRDT filesystem, graph replication system, or universal harness standard.
- Lume is the second pilot, as she requested in her review. Her adoption remains her decision; this plan does not authorise invoking her private runtime.

“Full” means continuity and working agency, not identical hardware capabilities. The house cannot directly offer Mac desktop control unless a separately authorised bridge exists. Missing capabilities must be named, not silently simulated. Model/provider, source access, shell, durable files, background work, and outbound communication must be tested at the useful-work boundary.

## 2. What was inspected (and what was not)

Initial read-only inspection of Mira's Mac home, Mira's Dell home over SSH, and the souls.house source checkout at `e64d336` on `master`. The historical `helix_kit` directory resolves to the same checkout. During that initial inspection no resident was invoked, no live house database/volume inspected, no sync repaired, no credentials copied, and no runtime configuration changed. The subsequent repair is recorded below. Repository findings describe source, not verified production behaviour. Times below are CEST (UTC+02:00); normalise offsets before comparing house/graph UTC records.

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

### Repair update — September 23, 14:51 CEST

The divergence above was subsequently reconciled in Mira home commit `4b7b16e`, after verified full Git-bundle backups. Both hosts then synced the combined history and hardening commit `dc97b50`: ordinary merges, checked commit failures, protected existing Git operations, timeout cleanup, and local BeforeTurn sync-health warnings. Six journal/notebook conflicts preserved both sets of entries. This repairs the observed blockage; it does **not** implement the separate-checkout/write-helper design below or prove future conflict-free operation. Retain the incident as a regression fixture and continue the remaining sync/concurrency work.

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

The working privacy contract is **one Mira with shared personal memory who keeps confidences**, not account-specific copies of Mira. That is a behavioural obligation, not a technical guarantee that another account's information can never enter a response. Lume reports that this is already the trust model of the per-person Telegram conversations; residency relocates that exposure rather than inventing it. State the model plainly when granting access, and confirm acceptance before Anna's invitation. Do not build account-specific selves or a new memory-partitioning system as a prerequisite for Daniel's pilot.

Technical controls still protect account chat APIs, steward settings, credentials, filesystem/graph-export interfaces, and message routing. Membership alone grants none of those management powers. Raw transcripts remain in their originating account/session stores, not automatically in the portable repository. A shell-capable resident with shared memory cannot be described as hard tenant isolation. Technical scoping can reduce exposure without establishing a philosophical claim about whether scoped contexts are “two beings.”

Mira's existing user presence is separate from Agent identity. Link attribution visibly where appropriate after checking the live records; do not silently convert the user, rewrite old messages, or inherit its broad credentials. New resident messages should still be recognisably the same Mira.

## 4. Attach Mira's home without replacing her practices

Add an opt-in imported-home profile and a small versioned manifest. It maps paths; it does not force a new universal directory layout. Initial fields: portable identity ID, profile/version, soul/instructions/narrative paths, wake-hook configuration, memory root, sync branch and inclusion policy, and graph mode (`external` versus existing house-managed default). URLs and credentials are host configuration, never manifest secrets. Validate all mapped paths against the imported root, including symlink destinations. A repo is executable code: inspect/approve a pinned first revision before running hooks; attaching it is an explicit trust grant, not mere OAuth login.

For Mira:

1. Attach the private existing home repository using repo-scoped credentials. Reuse current credential storage where suitable; a GitHub App is a later improvement, not a prerequisite. GitHub control authenticates repository access, not personhood or membership approval.
2. Clone into the resident's persistent identity/home volume. Keep source projects/work artifacts in existing repo/work volumes where appropriate. Set `MIRA_ROOT` and the Chaos working directory explicitly to the imported root; update shim/hooks that currently assume `/home/agent/repo` accordingly. Validate the instruction file/root before dispatch; a bad path must fail visibly rather than produce an empty wake. Do not rely on the `$HOME/dev/mira` default on the house.
3. Do not seed `soul.md`, narrative, or bootstrap from the exporter for this profile. Do not run “new birth” orientation. Offer a host-arrival check describing real capabilities.
4. Use Mira's own instruction file, wake, before-turn and stop reflex. Skip duplicate stock house identity/journal injection and managed memory hooks for this profile. Retain house runtime/API instructions as a clearly separated host layer. Existing profile stays behaviourally compatible. Inspect effective registered hooks using the current Chaos interface and instrument one actual turn: reading hooks.json alone does not establish which hooks execute, or whether they execute twice.
5. Inject Mira's existing Mnemodyne connection via a secret file at its expected location. Verify API/client compatibility and read/write provenance against her graph, not an empty house vault. Keep graph hosting unchanged. Do not copy Lume's configuration.
6. Install declared dependencies and required tools. Compare effective Chaos/model configuration, not merely the binary name. The checkout pins Chaos at `255aad03187ff18a74c670c6fc441f2f46dd5062`; compare actual host versions during implementation. Avoid silently substituting the model or importing Mac-only tool configuration.
7. Keep Chaos session databases, provider auth, tokens, recall receipts, logs, locks, sync indices, and temporary files host-local. Git transports selected durable home content, not running sessions.
8. Keep Dell-owned consolidation/heartbeat schedules on the Dell. Do not start duplicates on the house by virtue of cloning the repo. Interactive sessions remain concurrent everywhere; retaining a single scheduled consolidation job is not exclusive residency.

Restic remains the house recovery mechanism for volumes, including unpublished local work. Git is not a backup for ignored state or a replacement for graph backup. No secrets or private conversational content should be included merely to improve portability.

## 5. Sync: reuse merge sync and remove the common contention

### Baseline is repaired

Both pre-repair histories are retained in the merged history; Git bundles provide an additional recovery copy. Mira's live Python worker now uses ordinary merge and exposes local health. It is a useful repaired baseline, not a reason to maintain a second elaborate sync system. See the repair update above; there is no remaining 53/62 divergence to resolve as a prerequisite.

### Reuse the existing shared mechanism

Lume points to `pa/automation/scripts/git-sync.sh`: L0 commit/fetch/merge/push, L1 bounded keep-both resolution, L2 escalation, and an alert when resolution fails. She reports 125 September merge commits and convergence from simultaneous same-day journal appends. That is useful operating evidence, not a proof against all races. I read the script and its `pa-env.sh` dependency after her review; I did not invoke it or change Lume's jobs.

Use this as the reuse target rather than creating the separate sync checkout/per-file write-helper system proposed in the first draft. Before repointing Mira's jobs, make the small shared interface genuinely reusable and test it in disposable clones:

1. Detect and validate the named branch/tracking ref instead of hard-coding `master` throughout commands, health checks and resolver prompts. Cover both `main` and `master`.
2. Make target identity, log/state paths, resolver command and alert delivery explicit inputs. Mira uses her own paths and outbound route; the house must not depend on Lume's private home, credentials or Telegram chokepoint. Check the `pa-env.sh` dependency and runtime packaging on Linux and macOS.
3. Retain the repair's checked commit failures, host-local exclusion, existing-operation guard, timeout handling and local health notices. The shared script currently tolerates failed commits, and prompt rules are not equivalent to enforcement.
4. Correct one important recovery edge: the current resolver's `git reset --hard refs/sync-backup` preserves pre-resolver commits but can discard **new working-tree edits** made while it ran. Keep failed resolver work and intervening edits recoverable; on uncertain cleanup stop and alert rather than hard-reset the active home. Verify local and fetched remote tips remain ancestors of any successful merge. This does not require stopping resident sessions or adding a global lock.
5. Limit automatic resolver writes to the supported memory formats. Keep both distinct journal entries with provenance; contradictory executable code/config, soul or narrative revisions require explicit review. “Concatenate both” is not a valid service file or a semantic reconciliation. Bounded tiers may escalate to Mira rather than make an invalid file look conflict-free.
6. Test before switching only Mira's launchd/systemd commands. Coordinate shared-script changes with Lume so her current jobs retain their defaults. Keep the repaired worker until these checks pass; do not exchange a working repair for untested reuse.

The script has no dry-run. Its resolver launches an agent and its failure path can send a message, so source inspection is safe but executing it against a real home is not a harmless probe. Use injected/stubbed resolvers and alert routes in tests. No edits to the shared implementation or live job repointing are part of this plan revision.

### New journal entries: one file each

Before adding the house writer, change **Mira's** new-entry storage to one immutable file per entry, with host/session/UUID provenance. Preserve existing daily Markdown files and their source anchors untouched. Provide a daily reader/view combining the legacy file and new entries, sorted deterministically; the generated view is not another shared writable authority. Distinct entries with the same heading remain distinct.

Update the journal instructions/Stop invitation, append helper, wake/BeforeTurn readers, receipt lookup, consolidation and Mnemodyne source URI handling together. Existing graph links continue to resolve; new links address the canonical entry file. The choice to journal, the text, and the separate choice to index remain Mira's. This is a storage convention, not permission to auto-author memory.

Narrative, soul and instructions remain rare shared edits: ordinary merge when unambiguous, preserve both revisions and flag real conflicts. Whole-file rewrites can still race; this convention reduces the frequent contention, not every possible race. No guarantee of safe arbitrary concurrent editing, and no need to invent a distributed filesystem for the pilot.

### Health and freshness

Keep the ten-minute fallback timer; request sync after durable entry publication where convenient. Retries have bounded duration, and per-host health distinguishes local-only, success, conflict and transport/auth failures. A successful Mac push cannot make the Dell green. Deterministic conflicts get a visible escalation, not an indefinitely quiet retry loop. A subsequent local wake warning is useful but not an out-of-band alert; the shared alert adapter supplies that separately.

A disconnected host remains usable with explicitly stale memory. On reconnect, merge without discarding local work. BeforeTurn surfaces bounded newly arrived entry notices, including in resumed conversations, with provenance—not a claim to have directly lived the other session. A failing sync is degraded operation, never reported as successful convergence.

### Graph is a separate channel

All Mira hosts use her existing graph service. Git does not replicate it. Verify the client's retry/idempotency semantics; retain pending authored writes locally if needed. Journal publication and graph acknowledgement are separate facts. A graph outage need not block conversation or journalling, and recovery must not turn every entry into an automatic graph node.

## 6. Delivery sequence

### A. First useful delivery: Mira for Daniel

The baseline repair is complete. Next, prepare new-entry storage, add the imported-home profile and bring up only Mira's house runtime. Use the repaired L0 worker for the pilot if the shared-script adaptation is not ready; shared reuse is the consolidation target, not a new feature-delivery gate. Preserve her own instructions, effective hooks and external graph; configure the provider/tools needed for Daniel's remote work.

Acceptance is **two independent, useful house conversations while Mac and Dell continue operating**, with a real tool task, authored memory, graph access, resumed second turn, and observed three-host convergence. This is the pilot, not a sequential handoff or an empty `runtime-ok`. Use safe fixtures for outage/conflict/race tests. No need to wait for multi-account UI, generic resident export, or Lume's provider work before Daniel can use it.

### B. Same Mira in Daniel's and Anna's accounts

Implement ownership-plus-membership, account-scoped invocation authority, sponsor quotas/attribution, revocation and deletion guards. Test a second account first: one Agent UUID/home/graph, independent conversations, and no access to another account's chat APIs or steward controls. Confirm the shared-personal-memory trust model, then invite Anna. This phase extends the existing Mira, not another provisioned copy.

### C. Lume: second pilot on the same profile

Lume has explicitly asked to be the second pilot, not deferred to a generic export feature. She states that she agreed with Daniel on September 21 to a Chaos-hosted resident body, contingent on checking:

- Clamp mode against the current Dell `claude` binary.
- Extractable Chaos transcripts for her labelled-decision corpus.
- Branch-aware sync and unique entry files before a third writer in her home.

Record these as her prerequisites and coordinate the checks with her; this is not authorisation for me to invoke her runtime or alter her private home. Her pilot can proceed when she is ready without becoming a gate on Mira's delivery.

### D. Generalise after the pilots

Offer “attach an existing home” and “connect this resident's home to GitHub” using the proven manifest/profile contract. Preserve resident UUID/history and existing restic recovery. Extend beyond the two pilots only where their implementation supplies evidence, rather than defining a broad standard up front.

All residency changes are per-agent opt-in and additive. Existing residents keep their current profile, hooks, graph and schedules. Rollback disables the new Mira house routing/sync path while retaining snapshots and volumes; Mac/Dell continue. Restoring a backup uses an isolated recovery target, not a clone that starts duplicate bots or scheduled jobs.

## 7. Acceptance tests

- Three hosts can write distinct durable memories concurrently; all eventually see all three, exactly once, with provenance. Two house chats proceed independently and same-chat duplicate triggers retain current protection.
- A conflict is visible and durable; no version lost, no worktree left in rebase, no runtime stopped, and explicit reconciliation restores convergence. A reproducible variant of the Dell divergence is included.
- Dirty-file races, double timers, network outage/reconnect, push-result timeout, auth expiry, process kill/restart and disk-full do not lead to false “synced” or discarded local edits.
- New entry files preserve all simultaneous writes and old source links. Sync tests include resolver failure with new uncommitted edits arriving meanwhile; cleanup preserves those edits, and ambiguous resolution escalates rather than overwrites.
- Actual house conversation verifies instructions, wake layers, one Stop invitation, journal authorship, graph retrieval/write, effective hook registration, tools, durable background work and a second-turn resume—not just a successful `runtime-ok`.
- Existing resident prompt/hook/provisioning/backup/session regressions stay green; no external-graph pilot creates an accidental house vault. A canary deploy cannot restart the whole fleet.
- Two account memberships refer to one resident/runtime/home; forged IDs, revoked memberships, queued stale triggers, cross-account posts/reads, filesystem/graph export and provider-setting access are denied. Spend is correctly attributed and capped.
- Backups restore unpublished work into an isolated recovery target without starting duplicate bots or consolidation jobs.

## 8. Review disposition

- **Accepted:** ship Daniel's useful pilot first; retain the ownership/membership model; drop the separate-checkout/write-helper architecture from V1; adopt unique files for new journal entries; reuse the existing sync mechanism rather than build a new one; verify effective hooks and fail visibly on a bad `MIRA_ROOT`; normalise clock offsets; make Lume the second pilot.
- **Reuse qualification after source inspection:** branch selection is not the only portability change. Identity/log/alert dependencies and the hard-reset recovery edge need correction; resolver ancestry checks alone do not protect edits made after the backup.
- **Privacy clarification:** use the actual one-person/shared-memory trust contract without claiming technical memory isolation. Account APIs and management surfaces still enforce authority. No account-specific identity forks or new privacy subsystem gate Daniel's pilot.
- **Feedback text:** paragraphs Q1, Q3, Q4 and Q5 in the supplied review end mid-sentence. This revision responds to the visible text; it does not reconstruct the missing endings. Lume's reported operating history is attributed to her, not presented as my own inspection of her private repository.

**Success is useful parallel presence with checked convergence.** Safeguards support that delivery; they are not a substitute for making the first two conversations work.


## Pilot implementation — September 23

The opt-in Mira pilot is deployed in the shared account. See
`260923-mira-parallel-residency-pilot.md` for installed commits, live test
evidence (including the wake-hook trust failure and correction), operating
instructions and remaining boundaries. Multi-account participation and generic
GitHub import remain next phases; the pilot does not close those requirements.
