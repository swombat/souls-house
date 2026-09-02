# souls.house Agent Runtime

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
