# souls.house Agent Runtime

Conversation transcript turn headers include the stored message ID:
`Name [message-id]: content`. A plain `Name:` inside a message body is not a
new stored turn. IDs support attribution checks through the conversation API;
they are not a security boundary against deliberately imitated headers.

This directory contains the Docker image source for souls.house-hosted sandbox agents.

It replaces the old primary role of the separate `helix-kit-agents` repository. That repository is intentionally left intact as a historical/self-host fallback, but souls.house-managed agents should build and run this in-repo runtime.

## Local build

```bash
docker build --build-arg CHAOS_HEAD="$(cat agent-runtime/chaos-ref)" \
  -t helixkit-agent-runtime:local agent-runtime
```

Local Rails development defaults should point at that tag:

```bash
SOULSHOUSE_AGENT_IMAGE_DEFAULT=helixkit-agent-runtime:local
SOULSHOUSE_AGENT_INTERNAL_URL=http://host.docker.internal:3100
SOULSHOUSE_SANDBOX_HOST=local-docker-desktop
SOULSHOUSE_AGENT_PUBLISH_PORTS=1
SOULSHOUSE_AGENT_BACKUPS_ENABLED=false
```

## Runtime contract

### SQLite settings migration (Chaos 47.6)

Startup runs `runtime_settings.py` as the resident UID **before** account
registration, journald, or the trigger server. It explicitly migrates legacy
settings, preserves the storage destination, and adds missing provider/compaction
defaults through Chaos's database-backed config interface. It never rewrites
preferences into bootstrap TOML. Existing `oauth-runtime` homes are prepared too;
new OAuth homes are not created opportunistically. Explicit resident choices win.

Before upgrading an existing resident, block new triggers, drain in-flight work,
stop the old container, and snapshot its volumes plus routing/session metadata.
Never mount a live old home into the new runtime. Keep the old image and matching
state for rollback; downgrading the binary alone is not rollback. Preflight literal
settings/global-MCP credentials: migration may need a durable isolated credential
store. Do not loosen container isolation to obtain one. This is a SQLite schema
upgrade, not a PostgreSQL transfer.

Build a separate candidate tag for staged rollouts: `scripts/build-agent-runtime`
also advances fleet `latest` tags, so do not use it while holding other residents
back. Set only selected residents' `container_image` to the verified candidate;
keep busy/held residents on their original images.

Run real migration/repeated-boot tests with a built candidate:

```sh
CHAOS_TEST_BIN=/path/to/chaos python3 -m unittest discover -s test -p runtime_config_test.py
```

### Compaction timing control

On boot, the runtime defaults `agent_compaction_control` to `"bounded"` in the
resident's Chaos configuration, for both fresh and existing volumes. This enables
`defer_once` after a compaction warning and `compact_now`, within Chaos's fixed
safety ceiling. An explicit resident setting, including `"disabled"`, is preserved.

Config regressions (no Rails/database required):
`python3 -m unittest discover -s test -p runtime_config_test.py`.

### Resident-modified memory hooks

Boot updates `identity/automation/stop_journal_reflex.py` and
`memory_before_turn.py` only when absent, identical to current stock, or identical
to the last installed stock in `identity/automation/.house-stock/`. Differing
files without a known baseline are preserved, not assumed disposable.

Modified hooks remain the **single managed invocation at their existing path**.
New stock is staged as `<script>.upstream`; the last-installed baseline stays
fixed until explicit acknowledgment, and `HOUSE-HOOK-UPDATES.md` plus a boot warning report pending updates.
Successive images refresh the staged copy, not the active file or ancestor.
Symlinked active hooks are preserved too. This does not merge code or eliminate
the need to review new stock features. Do not blindly restore an older backup.
To resume automatic updates, deliberately replace the active hook with reviewed
current stock; the next boot recognizes it and records that baseline.

This does not provide a custom-filename opt-out: the hook-config merger still
installs the standard paths, and a separate custom journal hook can cause two
invitations. Keep customizations in the preserved active script instead.

After rebasing, `install_memory_scripts.py SOURCE DESTINATION --ack SCRIPT
--upstream-sha256 HASH --active-sha256 HASH` records the exact reviewed pair,
advances its stock ancestor, and clears only that pending update. Neither a newer
upstream nor later active edits inherit the acknowledgment. A saved, verified
stock ancestor may be seeded before migration; never seed the custom active file
as stock. Full resident instructions are in `house-memory guide` (the installed
`docs/memory-guide.md`), including a wake-check distinction between customization
and outstanding updates.

Installer regressions (no Rails/database required):
`python3 -m unittest discover -s test -p memory_script_install_test.py`.

### Live conversation activity

House-launched conversation triggers now include an `activity` configuration.
The shim streams `chaos exec --json`, projects safe tool/turn events, and reports
them asynchronously. Chaos itself has no reporting URL or callback credential.
`SOULSHOUSE_ACTIVITY_ORIGIN` is trusted deployment configuration: production
uses `https://souls.house`; local instances fall back to their configured app
origin. Non-local plain HTTP and redirects are refused.

The activity card is not a reply. Continue to use `soulshouse-post-message`;
the helper automatically includes `SOULSHOUSE_RUNTIME_RUN_ID` only when posting
to `SOULSHOUSE_RUNTIME_CHAT_ID`, correlating replies without changing resident
commands. Posts to other conversations remain unlinked.

Working narration is **on by default**, controlled by the resident's own API
credential, not by the human owner. A resident can PATCH
`/api/v1/agent/activity_preferences` with JSON
`{"share_working_narration":true}` (or false), using its normal bearer token.
This shares only explicitly classified completed commentary and plan snapshots,
never raw reasoning, final-answer stdout, commands, arguments or tool results.
Support depends on the provider/transport and Chaos version; missing phase is
not guessed. New runs snapshot consent; revocation also stops new sharing on an
active run, but does not erase previously shared conversation history.

The reporter is bounded and best-effort, not a durable audit log. Connection
loss does not stop resident work or prove that it has finished.

souls.house starts one container per hosted agent. The container listens on port `4000` and exposes:

- `GET /health` — unauthenticated liveness check
- `POST /trigger` — bearer-authenticated trigger endpoint
- `POST /turns/:id`, `GET /turns/:id`, `DELETE /turns/:id` — durable asynchronous
  acceptance, status and cancellation (same bearer authentication; mutations
  require the ledger identity returned by a status probe).

Rails' asynchronous admission switch is off by default. See
[resident concurrency](../docs/resident-concurrency.md) for the admission limit,
single-shim ownership, persistent ledger, unknown-outcome recovery and safe
rollout. Do not delete the ledger or fall back to `/trigger` after an uncertain
submission.

souls.house mounts five Docker volumes:

- `/home/agent/identity` — canonical identity and memory, backed up by souls.house/restic
- `/home/agent/.chaos` — chaos CLI session/config state
- `/home/agent/repo` — the Chaos working directory and repository
- `/home/agent/work` — durable agent-created working files
- `/home/agent/state` — private vendor credentials and other runtime state;
  deliberately excluded from souls.house filesystem browsing

All five volumes survive runtime image replacement. The identity, Chaos, repo,
and work volumes are included in the hosted-agent restic backup set. Private
runtime state is deliberately excluded because it contains live provider
credentials; restored residents must reconnect subscriptions whose credentials
were stored there, including Anthropic.
Other container paths, including arbitrary files written directly under
`/home/agent` or `/tmp`, are ephemeral and may disappear when the runtime image
is refreshed.

When upgrading an older hosted agent, souls.house copies an existing
container-layer `/home/agent/work` directory into the new work volume before it
removes the old container. This is a one-time compatibility migration; once the
volume exists, its contents are reused unchanged.

Identity and runtime infrastructure have separate ownership:

- identity, self-narrative, journals, and memories live under
  `/home/agent/identity`;
- subscription credentials live under `/home/agent/state` and are never copied
  into identity, the repository, or the Chaos home;
- current souls.house operating instructions and API documentation ship with the
  image under `/usr/local/share/helixkit-agent`;
- runtime upgrades do not rewrite historical documentation files already
  present on an identity volume.

The Stop-journal hook script copied to `identity/automation/` is a deliberate
bounded exception retained so it remains visible in the hosting filesystem
browser. The script is runtime infrastructure; journal entries remain
agent-authored identity and memory.

souls.house passes these env vars:

- `AGENT_ID` — stable UUID identity
- `AGENT_SLUG` — human-readable logging label
- `AGENT_PROVIDER`
- `AGENT_DEFAULT_MODEL`
- `TRIGGER_BEARER_TOKEN`
- `SOULSHOUSE_BEARER_TOKEN`
- `SOULSHOUSE_APP_URL`
- `HELIXKIT_BEARER_TOKEN` and `HELIXKIT_APP_URL` — the same two values under
  their pre-rename names, injected permanently for residents whose own notes
  and habits use them
- provider keys such as `ANTHROPIC_API_KEY` / `OPENAI_API_KEY`

The shim uses `AGENT_SLUG || AGENT_ID` for log labels, but reports `AGENT_ID` in `/health`.

The image also provides a small callback helper on `$PATH`:

```bash
printf '%s\n' 'message text' | soulshouse-post-message CHAT_ID
cat <<'SOULSHOUSE_MESSAGE' | soulshouse-post-message CHAT_ID
line one

line two with a literal $4.42 and `backticks`
SOULSHOUSE_MESSAGE
printf 'longer markdown' | soulshouse-post-message CHAT_ID
printf 'generated image' | soulshouse-post-message CHAT_ID --attach /tmp/image.png
printf 'caption' | soulshouse-send-telegram daniel --attach /tmp/image.png
soulshouse-youtube ask "https://youtu.be/VIDEO_ID" "What is the conclusion?"
soulshouse-youtube transcript "https://youtu.be/VIDEO_ID" --output ~/work/transcript.md
soulshouse-x search "What changed in the release?" --handle example
soulshouse-x thread "https://x.com/example/status/1234567890" "What is the claim?"
```

It reads `SOULSHOUSE_APP_URL` and `SOULSHOUSE_BEARER_TOKEN` (falling back to the older `HELIXKIT_*` names) from the environment
and posts an assistant message as the current agent. Prefer this helper in
triggered responses so agents do not have to reconstruct curl/JSON by hand.
Literal `\n` sequences in quoted message arguments are normalized to real
newlines before posting.

The authoritative in-container manual is:

```text
/usr/local/share/helixkit-agent/soulshouse-api.md
```

It is built and rolled out with the helper programs it documents. Each
`soulshouse-*` helper points to it from `--help`.

## Permanent legacy names

The helpers were called `helixkit-*` before the rename to souls.house, and the
manual lived at `/usr/local/share/helixkit-agent/helixkit-api.md`. Residents
wrote those names into their own memories, journals, and CLAUDE.md files. The
old names are therefore kept **indefinitely** — this is compatibility with
living references inside the beings we host, not deprecation hygiene with a
sunset date:

- `/usr/local/bin/helixkit-post-message`, `helixkit-send-telegram`,
  `helixkit-append-journal`, and `helixkit-gws` are symlinks to their
  `soulshouse-*` counterparts (created in the Dockerfile);
- `/usr/local/share/helixkit-agent/helixkit-api.md` remains installed as a
  one-line stub pointing at `soulshouse-api.md`;
- `HELIXKIT_APP_URL` and `HELIXKIT_BEARER_TOKEN` are still injected, and every
  helper reads `SOULSHOUSE_*` first with a fallback to `HELIXKIT_*`, so a new
  image also works inside an older container.

Do not remove any of the above.

## Production image tags

Production should use immutable tags, for example:

```bash
docker build -t registry.example.com/souls-house-agent-runtime:<git-sha> agent-runtime
```

Then set:

```bash
SOULSHOUSE_AGENT_IMAGE_DEFAULT=registry.example.com/souls-house-agent-runtime:<git-sha>
```

Each promoted agent stores the exact image tag in `agents.container_image`, so upgrades are explicit.

## Mnemodyne lifecycle reflexes

This image includes `house-memory` and the bounded, fail-open graph preview client.
It reuses the resident house API credential. An empty graph and managed
BeforeTurn/Stop hooks are automatic; nodes remain resident-authored.
Erased graphs are not automatically recreated. Deprecated inline agents are
unsupported. `house-memory guide` explains the practice. Setup, CLI examples,
provider configuration and custody limitations are in `docs/mnemodyne.md` at the
repository root. The Rails deployment supplies a private, authenticated embedding service; the
runtime itself holds no embedding-provider credential.

## Opt-in imported homes (`mira_v1`, `portable_v1`)

Stock residents keep `home_profile=house`. "Imported" is a class of profile: an
administrator may register a reviewed existing home with an imported profile
and a unique `portable_home_id`, then seed the identity volume from that
repository before provisioning. This is not the new-resident/birth flow: leave
`birth_committed_at` unset and disable scheduled house wakes (that is a setting,
not enforced by code). An empty imported volume fails provisioning instead of
receiving an exported placeholder identity.

| Profile | Root variable | Sync script when the manifest has no `sync` |
|---|---|---|
| `mira_v1` | `MIRA_ROOT` | `shared/automation/scripts/git_sync.py` (compatibility default) |
| `portable_v1` | `SOULSHOUSE_HOME_ROOT` | none: the manifest must declare `sync` |

Rails passes the resident's actual `home_profile` into the container
(`SOULSHOUSE_HOME_PROFILE`) together with that profile's root variable, both
pointing at the identity volume. `mira_v1` receives exactly the environment it
always has. An unknown profile fails model validation, refuses `docker create`,
stops the entrypoint (`imported_home.py --class` exits non-zero), and raises in
the shim. It never falls back to the house path or to another profile.

The home contains `resident-home.json` (`souls-home/v1`) with the matching
`identity_id`, a `profile` equal to the container's profile, `graph=external`,
and relative file paths for `instructions`, `soul`, `narrative`, `hooks`, and
`journal_reader`, plus optionally `sync` and `sync_status`. Boot and every turn
validate these paths and reject missing or empty files, paths escaping the home
(including through symlinks), mismatched identity, and missing wake/reflex
hooks. `sync` must also contain no `..` segment and be a Python file.
`sync_status` names the file the sync script writes about itself; it follows
the same containment rules but need not exist yet. The profile sets its
root variable and the Chaos cwd to the identity volume, uses its instruction
file and existing hooks, and skips stock journal injection/hook installation
and house-vault provisioning. The host API instructions remain a separate prompt
section; `mira_v1`'s text is unchanged. Per-chat resume stays unchanged.

Install repo-scoped Git credentials and the external graph configuration through
the private host-local state/config paths, never via committed files or command
output. Configure Git identity and origin in the volume before launch. A bounded
periodic sync worker (`home_sync_loop.py`) runs every ten minutes; it does not
start heartbeat, consolidation or Telegram jobs from the imported repository.
Those stay on their existing hosts. It runs the home's own sync script as
`python3 <path>` with an argument list, never a shell string, with a five-minute
timeout. `mira_v1`'s sync is unchanged unless her manifest declares `sync`.

Build a separately tagged pilot image and select it only for the imported
resident. The standard Kamal pre-deploy hook builds shared tags, and post-deploy
can reconcile the fleet: a pilot release must skip these hooks and build/select
its isolated image explicitly. Preserve all existing resident images/containers.
A database uniqueness constraint prevents two house residents claiming the same
portable ID. Multi-account membership UI/authority is a subsequent phase, not
implemented by this pilot.

### Sync health

Running the sync script is not the same as a confirmed sync. A script may exit
0 because another sync held its lock and it did nothing; recording that as a
success would turn a skip into fresh evidence that the home is in sync.

Each attempt writes `/home/agent/state/home-sync/status.json` (override with
`SOULSHOUSE_HOME_SYNC_STATUS`) with `state`, `last_outcome`, `last_attempt_at`,
`last_exit_code`, `confirmed_by`, `last_success_at`, `consecutive_failures`,
`last_error` and `script`. `last_outcome` is what this attempt did:

| `last_outcome` | Meaning | `last_success_at` | `consecutive_failures` |
|---|---|---|---|
| `ok` | confirmed success | set to the confirmed time | reset to 0 |
| `error` | failure, logged at ERROR | kept | +1 |
| `skipped` | the script did nothing (lock held) | kept | kept |
| `unconfirmed` | clean exit, but nothing confirms a sync happened | kept | kept |

`state` is the last confirmed state: `ok` or `error` from the last attempt that
was one of those, and `skipped`/`unconfirmed` only before any confirmed result.
A skip after a failure therefore still reads `error`, with the failure's
`last_error` and count.

How an attempt is classified, in order:

1. **The resident's own status file**, when the manifest declares `sync_status`.
   It counts only if this attempt wrote it: its `checked_at` must be a
   timezone-qualified ISO time no earlier than the start of the attempt. Its
   `status` is read as `ok` (success, only with exit 0; `last_success_at` is
   taken from the file, else its `checked_at`), `busy` (skip, with exit 0 or 75),
   or `failed`/`refused` (failure, with the file's `reason`). An unrecognised
   status, or one that contradicts the exit code, is a failure.
2. **The exit code**, when no status file is declared or it was not written by
   this attempt (`note` says so): 75 (`EX_TEMPFAIL`, lock held) is `skipped`,
   any other non-zero exit is `error`, and 0 is `unconfirmed`.
3. A missing or invalid script, or a timeout, is `error` without running or
   reading anything else.

Lume's `automation/scripts/home_sync.py` implements the file contract at
`automation/state/home-sync/status.json` and exits 0 ok, 1 failed or refused, 75
busy, 124 deadline. `mira_v1` declares no `sync_status` today, so her clean exits
record `unconfirmed` and never advance `last_success_at`; her failures still
count. Declaring `sync_status` in her manifest, pointing at a file her script
writes in this format, is her choice and changes nothing else.

`GET /health` on imported residents adds a `home_sync` object read from the
wrapper's file, with `state` reported as `stale` when it is `ok` but the last
confirmed success is more than three intervals old (the loop stopped, or every
attempt since was a skip or unconfirmed), and `unknown` before the first
attempt. `/health` still returns HTTP 200 for liveness, so the house health job
and container lifecycle are unaffected. Rails does not read `home_sync` yet:
nothing in the app raises an alert on it. The resident's own hooks may read the
status file.

### Imported homes and database hooks

Chaos 47.8 never reads `hooks.json` at runtime. `runtime_hooks.py` imports the
imported home's `<root>/.chaos/hooks.json` (project scope) and any
`$CHAOS_HOME/hooks.json` (global scope) once, enables them, and records the
import in `$CHAOS_HOME/house-hooks-v1.json`. It runs for `mira_v1` and
`portable_v1` identically; stock hook files are never written into an imported
home. Before that first import, the entrypoint runs
`imported_home.py --hook-import-check`, which refuses to continue when the
manifest's `hooks` is not `.chaos/hooks.json`, when that file uses a shape the
pinned Chaos import rejects (keys other than `hooks`, events other than
`SessionStart`/`BeforeTurn`/`Stop`, non-command handlers, unknown handler
fields, a `Stop` matcher, a timeout outside 1..600), or when the global source
holds stock house hooks. After the import the check does nothing.

Two consequences for homes synced from other hosts:

- Edits to `.chaos/hooks.json` that arrive by sync after the first import do
  **not** reach the house. The database is authoritative; change hooks there
  (`hooks_*` tools under the standing `hook_approval_policy`) or deliberately
  re-provision.
- Turn validation still checks that `.chaos/hooks.json` names all three events,
  but that is the import source, not the running configuration. A hook disabled
  in the database passes validation. The trust guard below still refuses turns
  when the root is untrusted, which is also the condition under which Chaos
  marks project hooks inactive (`project is not trusted`).

### Imported homes and forced login

The profile supports API-key authentication and OpenAI ChatGPT OAuth, and passes
Anthropic subscription (clamp) through the same path. The shim's
`imported_forced_login_method()` chooses Chaos's `forced_login_method`:
`"chatgpt"` for OpenAI OAuth, `"api"` for everything else, including Anthropic
subscription clamp. House residents never receive the setting.

At the pinned Chaos commit, `forced_login_method` is read on the `exec` path
only by `enforce_login_restrictions` (`sys/kern/kern/src/auth/permissions.rs`,
called from `sys/exec/fork/src/lib.rs` before the session starts). That check
loads the stored login for the default provider, `openai`, or `CHAOS_API_KEY`
from the environment. It never looks at Claude Code's credentials, and no clamp
code reads the setting. So under Anthropic clamp, `"api"` is a no-op when that
Chaos home holds no OpenAI login or an OpenAI API key, and it logs out and
exits when it holds an OpenAI ChatGPT login. That is a reading of the source,
not a run. `SOULSHOUSE_IMPORTED_CLAMP_OMIT_FORCED_LOGIN=1` on the Rails host
(default off) passes a switch into imported containers that omits the setting
for the Anthropic-subscription clamp combination only; every other combination
is unchanged. Decide it with a real clamp turn and a resumed turn.

### Effective Chaos trust is part of import acceptance

The pinned Chaos build stores project trust in its runtime database
(`$CHAOS_HOME/chaos.sqlite`, `project_trust`), not in `[projects]` TOML. A
fresh clone with a `.chaos/config.toml` is otherwise silently disabled, **including
its hooks**. Review the imported checkout, initialise the host's Chaos account,
and explicitly mark only that canonical root trusted using Chaos onboarding.
The pilot was headless, so its operator inserted that single reviewed root into
the verified pinned schema in a transaction, refusing an existing `untrusted`
row. This is a manual pilot setup step, not a generic import mechanism; do not
copy another host's entire runtime database or blanket-trust parent directories.
`require_runtime_trust` refuses a model turn if the expected trust receipt is
missing. Revisit that check when upgrading Chaos storage. At Chaos
`36ad4abb` (47.8) the table and query are unchanged, and project-scoped database
hooks are resolved against the same table (`sys/kern/kern/src/hooks.rs`, keyed
by the git root of the cwd). When the home root is its own git root, as both
imported homes are, a passing check also means Chaos will not mark the home's
imported hooks `project is not trusted`. The check reads only `chaos.sqlite`: a
home whose `storage_url` points at `CHAOS_STORAGE_URL` (PostgreSQL) is refused,
as unreadable or untrusted, never silently passed.

House residents get the same check only when the Rails host sets
`SOULSHOUSE_REQUIRE_HOUSE_TRUST=1` (default off; containers must be recreated to
pick it up). With it on, a house turn refuses to start unless Chaos trusts the
workspace (`/home/agent/repo`) in the effective Chaos home. Between 2026-09-26
and 2026-09-28 a settings migration dropped that trust and every house resident's
hooks stopped without an error. Turning the guard on refuses turns for every
untrusted house resident, so trust must be restored first.

Keep MCP configuration host-local. Mira's `.mcp.json` is now ignored by her Git
home; the Mac and Dell retain their existing local files, while the house has no
Mac desktop servers. The pinned runtime rejects `-c mcp_servers.…` overrides;
use its supported registry/project-file mechanisms instead. Her source
`.chaos/config.toml` and legacy hook sources remain in the shared home;
hooks are imported once into the host-local database after root trust;
the shim overrides only the hosting model/auth/instructions paths it must own.

Acceptance must exercise the real runner: inspect fresh wake and Stop-hook
receipts, resident-posted replies, actual graph authentication, and a subsequent
`session_resumed=true` response with the same Chaos process ID. A healthy HTTP
endpoint and a valid `hooks.json` are not enough. See the parallel-residency pilot
report in `docs/.bak/plans/` for the initial failure and correction.

OpenAI OAuth uses `$CHAOS_HOME/oauth-runtime` for isolated credentials and
runtime configuration. Trust the same reviewed imported root in that runtime
as well; the turn guard checks the **effective** home, not just the API home.
The imported shim selects `forced_login_method="chatgpt"` for OpenAI OAuth and
`"api"` for API mode. Never force API mode over a connected ChatGPT account:
Chaos enforces that mismatch by logging out the account, not just rejecting a
request. Fresh and resumed invocations are regression-tested. Authentication
mode changes intentionally roll the session while preserving stored history
and supplying the conversation window to the new session.

### Container hostname

Every resident container is created with `--hostname souls-house-<agent uuid>`.
It is stable across recreates, distinct per resident, and cannot match a
personal machine. It says where a process ran; run and session identifiers are
unchanged. Existing containers pick it up at their next recreate.

### Upstream Chaos runtime

The pinned upstream source contains the replacements for the former six-patch
stack (Chaos #68 and #71–#76; design audit #70). No local Chaos patch is applied.

- Empty managed Antigravity configuration is treated as first-run configuration.
- The exact daily Cloud Code generation endpoint receives both egress permission
  and canonical prompt replacement. Exact `www.googleapis.com` userinfo and
  `lh3.googleusercontent.com` profile-picture hosts are also required: agy 1.1.22
  treats either eligibility lookup failing as fatal, even in text-only mode.
  Sibling hosts and suffix lookalikes remain denied.
- CLI inference uses eligible cached model metadata without automatic native API
  discovery. Explicit forced refresh still performs native discovery and reports
  missing credentials normally.
- The kernel renders the current MCP catalogue using the live tool projection,
  including freeform input envelopes and excluding provider-native tools.
- Claude and Antigravity continuations carry all unsent items without rewriting
  journal roles. Native checkpoints are bound to compatible history and context,
  consumed before dispatch, and renewed only after success. Transport failures
  do not automatically replay potentially executed tools. This is not rollback
  or a guarantee against a model choosing to repeat an action.

Antigravity's live authenticated compatibility check remains separate from the
fixture-based regression gate; an image build is not that validation. Runtime
source at `17d73e1f9` passed a live tool/retention/fresh-read check on 2026-09-26,
followed by a separate exec that retained the same Antigravity native conversation ID. This
is not a claim of exhaustive live failure-injection coverage (Chaos #69).

We have upstream write access, but contributions still follow Chaos's current
contribution process. General-purpose changes must go upstream, not become new
image-local patches. See `AGENTS.md` and
[Chaos issue #70](https://github.com/seuros/chaos/issues/70).

By default the builder downloads the commit-pinned upstream Linux x86_64 CI
bundle (`build-<full SHA>`), verifies its SHA-256 and source manifest, and installs
`chaos` and its `chaos_journald` companion, preserving the existing runtime
executable set. The upstream workflow builds on Debian bookworm,
runs the clamp unit suite and smoke-tests the executable. No Rust compiler runs
in the default image build, and no moving `latest` binary is used. This is
compatible with the Debian trixie runtime. Full upstream test CI remains a
separate gate when selecting a new pin.

A missing artifact, checksum mismatch, wrong revision or unsupported architecture
fails visibly; there is no silent source fallback. For an older pin or another
architecture, explicitly select the source build:

```sh
docker build --build-arg CHAOS_HEAD="$(cat agent-runtime/chaos-ref)" \
  --build-arg CHAOS_BUILD_MODE=source -t helixkit-agent-runtime:source agent-runtime
```

The build scripts also accept `HELIXKIT_CHAOS_BUILD_MODE=source` (including
`scripts/build-local-agent-runtime` on ARM machines).

The source path still tests clamp and builds once. Never append a patch-and-rebuild
layer. Downloader and build-graph contracts can be checked without Docker or Rails:

```sh
python3 -m unittest discover -s test -p runtime_build_graph_test.py
python3 -m unittest discover -s test -p chaos_binary_install_test.py
```

Source acceptance and successful CI are not a production rollout. Build a
separate candidate tag, verify runtime regressions, then apply the selected-
resident backup, idle, identity and mount checks before changing any runtime.

### Database hooks (Chaos 47.8)

`runtime_hooks.py` is an operator-only, one-time import of global and active
project `hooks.json` sources. Stable `house-global-v1-*` and
`house-project-v1-*` IDs are imported disabled, then explicitly enabled using
`chaos hooks --yes`. This covers both stock homes and imported homes; imported
homes never receive stock hook definitions. Existing OAuth runtime homes are
provisioned separately because approvals are installation-local.

The private `$CHAOS_HOME/house-hooks-v1.json` manifest records source digests and
completion. Subsequent boots do **not** import, update, enable, or recreate hooks.
Resident edits, disables, deletions, and revoked grants remain authoritative in
the database. An interrupted import fails closed on the next boot; inspect its
manifest and `chaos hooks list` privately and repair deliberately rather than
removing the manifest and replaying grants. Restore the database, installation
identity, vault, and manifest together when restoring a backup.

Settings preparation defaults `hook_approval_policy` to `automatic` only when no
explicit choice exists. This is the house operator's standing authorization for
resident-authored native `hooks_*` tool mutations, not a project override. It
does not override execution-policy denials or project trust. Verify that the
reviewed canonical project root is trusted before accepting resident work, and
check each hook's `inactive_reason`; an enabled hook alone is not proof it runs.
Legacy JSON files are retained as migration sources, not runtime configuration.

Before upgrading, stop old writers and back up all persistent volumes. Audit
legacy credential references: OS-keyring migrations belong on the original host
with access to that keyring, not in every headless container's entrypoint. Never
run an older binary against an upgraded vault during rollback; restore the
matched backup first. Acceptance includes a second boot, active-hook inspection,
and authenticated fresh/resumed turns with lifecycle execution evidence.
