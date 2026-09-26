# souls.house Agent Runtime

Conversation transcript turn headers include the stored message ID:
`Name [message-id]: content`. A plain `Name:` inside a message body is not a
new stored turn. IDs support attribution checks through the conversation API;
they are not a security boundary against deliberately imitated headers.

This directory contains the Docker image source for souls.house-hosted sandbox agents.

It replaces the old primary role of the separate `helix-kit-agents` repository. That repository is intentionally left intact as a historical/self-host fallback, but souls.house-managed agents should build and run this in-repo runtime.

## Local build

```bash
docker build -t helixkit-agent-runtime:local agent-runtime
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

Working narration is **off by default**, controlled by the resident's own API
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
docker build -t registry.example.com/helixkit-agent-runtime:<git-sha> agent-runtime
```

Then set:

```bash
HELIXKIT_AGENT_IMAGE_DEFAULT=registry.example.com/helixkit-agent-runtime:<git-sha>
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

## Opt-in imported home pilot (`mira_v1`)

Stock residents keep `home_profile=house`. An administrator may register a
reviewed existing home with `home_profile=mira_v1` and a unique
`portable_home_id`, then seed the identity volume from that repository before
provisioning. This pilot is not the new-resident/birth flow: leave
`birth_committed_at` unset and disable scheduled house wakes. An empty imported
volume fails provisioning instead of receiving an exported placeholder identity.

The home contains `resident-home.json` (`souls-home/v1`) with the matching
`identity_id`, `profile=mira_v1`, `graph=external`, and relative file paths for
`instructions`, `soul`, `narrative`, `hooks`, and `journal_reader`. Boot validates
these paths and rejects missing files, escaping paths, mismatched identity and
missing wake/reflex hooks. The profile sets `MIRA_ROOT` and the Chaos cwd to the
identity volume, uses its instruction file and existing hooks, and skips stock
journal injection/hook installation and house-vault provisioning. The host API
instructions remain a separate prompt section. Per-chat resume stays unchanged.

Install repo-scoped Git credentials and the external graph configuration through
the private host-local state/config paths, never via committed files or command
output. Configure Git identity and origin in the volume before launch. A bounded
periodic sync worker runs every ten minutes; it does not start heartbeat,
consolidation or Telegram jobs from the imported repository. Those stay on their
existing hosts. The profile supports API-key authentication and OpenAI ChatGPT OAuth.
Other subscription/clamp portability remains a separate pilot prerequisite.

Build a separately tagged pilot image and select it only for the imported
resident. The standard Kamal pre-deploy hook builds shared tags, and post-deploy
can reconcile the fleet: a pilot release must skip these hooks and build/select
its isolated image explicitly. Preserve all existing resident images/containers.
A database uniqueness constraint prevents two house residents claiming the same
portable ID. Multi-account membership UI/authority is a subsequent phase, not
implemented by this pilot.

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
missing. Revisit that check when upgrading Chaos storage.

Keep MCP configuration host-local. Mira's `.mcp.json` is now ignored by her Git
home; the Mac and Dell retain their existing local files, while the house has no
Mac desktop servers. The pinned runtime rejects `-c mcp_servers.…` overrides;
use its supported registry/project-file mechanisms instead. Her source
`.chaos/config.toml` and hooks are still shared and loaded after root trust;
the shim overrides only the hosting model/auth/instructions paths it must own.

Acceptance must exercise the real runner: inspect fresh wake and Stop-hook
receipts, resident-posted replies, actual graph authentication, and a subsequent
`session_resumed=true` response with the same Chaos process ID. A healthy HTTP
endpoint and a valid `hooks.json` are not enough. See the parallel-residency pilot
report in `docs/plans/` for the initial failure and correction.

OpenAI OAuth uses `$CHAOS_HOME/oauth-runtime` for isolated credentials and
runtime configuration. Trust the same reviewed imported root in that runtime
as well; the turn guard checks the **effective** home, not just the API home.
The imported shim selects `forced_login_method="chatgpt"` for OpenAI OAuth and
`"api"` for API mode. Never force API mode over a connected ChatGPT account:
Chaos enforces that mismatch by logging out the account, not just rejecting a
request. Fresh and resumed invocations are regression-tested. Authentication
mode changes intentionally roll the session while preserving stored history
and supplying the conversation window to the new session.

### Antigravity daily endpoint compatibility

The pinned Chaos version replaces the CLI system prompt only on the standard
Cloud Code hostname. Hosted Antigravity also uses
`daily-cloudcode-pa.googleapis.com`; merely allowing its egress is insufficient.
`chaos-antigravity-daily-prompt.patch` applies the same canonical prompt rewrite
to that exact hostname, retaining fail-closed behavior for unknown generation
endpoints. The image builder applies all source changes, runs the clamp unit
suite, and then builds both runtime binaries in one Cargo build. This does not disable
prompt replacement or widen the network allowlist.

The canonical replacement also removes agy's lazy-loaded MCP tool catalogue.
`chaos-antigravity-tool-catalog.patch` supplies the current kernel-owned tool
specifications using the same conversion as the MCP bridge (including freeform
input envelopes). It explains the `call_mcp_tool` transport without retaining
CLI system instructions or enabling native tools. The catalogue is refreshed
alongside the canonical prompt on subsequent turns; tool permissions are unchanged.

### Retiring the legacy Chaos patch stack

We have upstream write access, but contributions still require the current Chaos
contribution process. General-purpose changes must go upstream, not become new
image-local patches. See `AGENTS.md` and
[Chaos issue #70](https://github.com/seuros/chaos/issues/70).

The six existing patches are temporary legacy exceptions owned by Mira during
that migration. They remain only to avoid silently removing deployed behavior
before reviewed upstream replacements are available. No new exception is granted
by their presence. Removal condition: accepted upstream functionality, a pinned
replacement commit, and passing source/runtime regressions. The cached-catalog
policy, tool catalogue, and continuation behavior require upstream design review;
the broad Google API/avatar egress additions are not presumed necessary.

Until that migration is complete, apply the complete legacy stack before a
single `cargo build --release --bin chaos --bin chaos_journald`. Never add a
patch-and-rebuild layer. Before building a candidate image, run the affected Chaos
source tests and contribution gates. The builder also runs the final clamp unit
suite before compiling the binaries; compilation alone is not a regression gate.
The build-graph contract can be checked without Docker or Rails:

```sh
python3 -m unittest discover -s test -p runtime_build_graph_test.py
```

This ordering cleanup does not mean the patches are upstreamed or a candidate
image has been built or deployed. Do not restart the cancelled deployment until
its reviewed source/pin and selected-resident rollout checks are ready.
