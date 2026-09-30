# Antigravity clamp — Souls.house follow-up

**Date:** 2026-08-10  
**Status:** Chaos PR #28 is merged at `2403367e5`; Souls.house integration is
underway with that revision pinned, the matching journald sidecar supervised,
and Gemini subscription turns routed through the shared Chaos MCP clamp bridge
**Sequence:** prove `agy` behavior → implement the transport in Chaos → integrate it here

## Proven spike

The local spike completed successfully on 2026-08-10. Its runnable evidence is
kept under `~/.local/share/mira-antigravity-spike`, and the removed
Souls.house proof-of-concept patch is archived under
`~/antigravity-clamp-scratch/2026-08-10`. Both locations are outside Git
worktrees and are development evidence, not a production layout.

Tested CLI artifact:

- version: `agy 1.1.11`
- platform: macOS arm64
- binary SHA-256:
  `198ff7c3f6d173daa510b0814aa70c6ce14c94035bcd4707a3c0e79fa38a7bc3`
- release archive URL and SHA-512 are retained in the spike's
  `download/manifest.json`

The OAuth ceremony succeeded against Daniel's Google AI Pro account using
`agy`'s own browser flow and private state directory. Neither Rails nor the
prototype read or reused the resulting OAuth token. Live invocations confirmed:

- a fresh non-interactive model turn;
- JSONL streaming with initialization, step, result, timing, and token-usage
  data;
- a stable provider conversation ID;
- explicit conversation resume in a later `agy` process;
- the resumed model retaining the prior turn;
- use of the subscription path without a Gemini API key.

Representative fresh invocation (paths are illustrative):

```sh
HOME=/private/antigravity-state agy \
  --print "$PROMPT" \
  --output-format stream-json \
  --model gemini-3.1-pro-low \
  --agent souls-house-clamp \
  --disable-slash-commands \
  --sandbox \
  --print-timeout 2m
```

Representative resume invocation:

```sh
HOME=/private/antigravity-state agy \
  --print "$PROMPT" \
  --output-format stream-json \
  --conversation "$PROVIDER_CONVERSATION_ID" \
  --model gemini-3.1-pro-low \
  --disable-slash-commands \
  --sandbox \
  --print-timeout 2m
```

Observed JSONL event envelope:

```json
{"event":"init","conversation_id":"<uuid>","init":{"model":"gemini-3.1-pro-low","permission_mode":"request-review"}}
{"event":"step_update","step_update":{"conversation_id":"<uuid>","step_index":1,"state":"DONE","step_type":"agent_response","text_delta":"...","usage":{"input_tokens":0,"output_tokens":0,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":0}}}
{"event":"result","result":{"conversation_id":"<uuid>","status":"SUCCESS","response":"...","duration_seconds":0.0,"num_turns":1,"usage":{"input_tokens":0,"output_tokens":0,"thinking_tokens":0,"cache_read_tokens":0,"total_tokens":0}}}
```

The spike established feasibility, not production equivalence. In particular,
`agy 1.1.11` advertises its built-in tool catalog in the `init` event even when
the selected custom agent declares `tools: []`. The spike used a transport-only
agent prompt, sandbox mode, and the default `request-review` permission mode,
and never enabled `--dangerously-skip-permissions`. Chaos support must not claim
that Antigravity tool isolation is complete until a tested deny mechanism or
Chaos-controlled MCP/permission bridge exists.

## Boundary

Google subscription use must remain behind Google's official Antigravity CLI.
Souls.house must not extract, copy, inspect, or call Google endpoints with
Antigravity OAuth credentials.

Chaos owns the model-transport behavior:

- launching `agy`
- model and reasoning-effort mapping
- prompt submission and conversation resume
- parsing Antigravity's stream-JSON output
- normalizing responses, failures, usage, and process/session identifiers into
  Chaos events
- disabling or isolating Antigravity tools so Chaos remains the tool and
  permission authority
- reporting transport availability and authentication state through a stable
  machine-readable interface

The archived Souls.house patch is evidence only. In particular, its
provider-specific `run_antigravity` shim and Antigravity JSON-to-Chaos
translation must **not** be restored once Chaos owns those responsibilities.

Souls.house owns deployment and user-facing account connection:

- installing a pinned, checksummed `agy` binary in the hosted-agent image
- mounting a private persistent vendor-state directory outside identity, repo,
  work, and Chaos-visible filesystem surfaces
- invoking Chaos with the Gemini subscription/clamp mode selected
- presenting connect, status, reconnect, cancel, and disconnect controls
- retaining display metadata only; never retaining OAuth tokens or browser
  return codes

## Chaos interface required before integration

Souls.house should wait for a released/pinned Chaos revision that provides:

1. A provider-neutral clamp/harness configuration with an Antigravity
   implementation.
2. Headless `chaos exec --json` support for fresh and resumed Gemini turns.
3. Stable normalized events for:
   - process/conversation start
   - assistant text
   - invocation usage
   - authentication-required failures
   - provider/transport failures
4. A machine-readable capability/status command. Souls.house must not scrape
   human-oriented CLI output.
5. A supported authentication ceremony boundary. It may delegate to `agy`, but
   secret credentials and one-time browser codes must never enter Rails,
   audit logs, or application logs.
6. Disconnect behavior that removes only Antigravity's private credential state
   and rolls affected persistent sessions.
7. Explicit capability reporting for the transport's tool-authority level.

Chaos now satisfies this integration boundary: `chaos exec --json` routes
Antigravity turns through the shared Chaos MCP bridge and emits the normalized
events listed above.

### Merged Chaos checkpoint — 2026-08-11

Chaos PR #28 merged into `master` at `2403367e5`.

The merged implementation includes:

- `AntigravityTransport`, using one sandboxed `agy` subprocess per model turn;
- explicit `clamp_backend = "antigravity"` selection while preserving
  `claude-code` as the default;
- reuse of the existing provider-owned Chaos MCP clamp lifecycle rather than a
  separate Antigravity command namespace;
- managed Antigravity MCP and permission configuration that denies native
  command, filesystem, and URL tools while exposing the real Chaos session
  tools;
- fresh-turn, in-process, and separate-process provider-conversation resume;
- parsing of observed `init`, `step_update`, and `result` JSONL records;
- normalized assistant output and usage in `chaos exec --json`;
- removal of metered Gemini API-key environment variables;
- classified missing-CLI, authentication, timeout, protocol, and invocation
  failures;
- unit and end-to-end tests with a fake `agy` executable and an ignored live
  smoke test using an authenticated isolated home.

The live transport smoke test passed on August 11, 2026 against `agy 1.1.12`
and the authenticated Google AI Pro account. A live end-to-end
`chaos exec --json` test also passed for both a fresh process and a later,
separate-process `chaos exec resume` invocation. The normalized stream contained
`process.started`, `turn.started`, an `item.completed` agent message, and
`turn.completed` with invocation and process-cumulative usage. The resumed turn
kept the same Chaos process ID and returned the exact marker from the prior
provider conversation. Fresh and resumed turns called real Chaos `read_file`
and `exec_command` tools through the shared MCP bridge, with canonical Chaos
tool lifecycle events. Both invocations reported complete token usage and no
failed turn.

The service-style smoke ran the matching `chaos_journald` binary explicitly and
passed its socket through `CHAOS_JOURNALD_SOCKET`. Per-command detached journald
bootstrap was not reliable for the longer live turn: the first model turn
succeeded, but the later process found a stale socket and timed out before
reaching Antigravity. Souls.house already has a resident-service architecture
and should run the Chaos revision's matching journald sidecar as a supervised
service rather than relying on per-command bootstrap.

The integration deliberately emits only the final result as normalized
assistant output. Incremental `step_update` exposure remains a later
enhancement; tool calls already appear through the canonical shared Chaos MCP
bridge events.

## Souls.house implementation after Chaos lands

### Runtime image

- Pin the tested Antigravity CLI version and artifact checksum for each
  supported architecture.
- Install the binary without running a shell-mutating installer or enabling
  self-update.
- Do not infer a production checksum for Linux from the macOS spike. Fetch and
  record the exact official Linux artifact manifest during the image change.
- Pin the Chaos revision containing Antigravity clamp support.
- Add build-time smoke checks for both versions.
- Install and supervise the matching `chaos_journald` binary from the same
  Chaos revision.

### Persistent state

- Keep Antigravity state under the existing private runtime state volume, for
  example `/home/agent/state/antigravity`.
- Keep Chaos's journal database and socket under supervised resident-service
  state, and pass the socket to workers through `CHAOS_JOURNALD_SOCKET`.
- Set `HOME`/vendor configuration variables only for the delegated
  Antigravity process.
- Ensure Gemini API keys are absent from the subscription transport
  environment, preventing accidental metered fallback.
- Use restrictive directory and file permissions.

### Trigger shim

- Remove all provider-specific Antigravity execution, JSON translation, model
  mapping, and resume logic from the shim.
- Continue invoking `chaos exec --json`; select the subscription transport via
  the stable Chaos configuration/CLI surface.
- Repeat the original `-m` model and the effective `clamp=true` /
  `clamp_backend=antigravity` settings on every resume invocation.
- Pass normalized Chaos events through the existing telemetry path.
- Roll a persistent session whenever provider, model, auth mode, or transport
  changes.

### Account connection API and UI

- Advertise Gemini subscription support only when the runtime's Chaos
  capability probe reports Antigravity available.
- Reuse the provider-subscription panel, but label the implementation as a
  first-party CLI connection rather than generic OAuth token custody.
- Surface verification URL and browser-returned code only for the live
  ceremony. Never persist or log either.
- Show connected/disconnected/expired state and a clear reconnect action.
- State that agent usage consumes the connected Google AI plan quota.

### Tests

- Runtime image contains the pinned `agy` and Chaos versions.
- API-key Gemini turns still use the metered provider path unchanged.
- Subscription Gemini turns cannot see `GEMINI_API_KEY`.
- Fresh and resumed turns preserve conversation identity through normalized
  Chaos events.
- The process is launched without `--dangerously-skip-permissions`.
- Antigravity native command, filesystem, and URL operations remain denied
  while Chaos tools work through the shared MCP bridge.
- Auth-required errors map to reconnect UX.
- Tokens and browser codes are absent from database rows, audit payloads,
  Rails logs, shim logs, and filesystem surfaces exposed by Souls.house.
- Container recreation preserves the private Antigravity connection; explicit
  disconnect removes it.

## Rollout

1. Enable for one internal Gemini agent.
2. Compare response correctness, resume behavior, and usage telemetry against
   metered Gemini.
3. Observe plan quota and throttling for several days.
4. Retain API-key fallback as an explicit user choice, never an automatic
   fallback from a failed subscription invocation.
5. Expand only after the pinned `agy` and Chaos combination is stable.
