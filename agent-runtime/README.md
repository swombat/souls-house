# HelixKit Agent Runtime

This directory contains the Docker image source for HelixKit-hosted sandbox agents.

It replaces the old primary role of the separate `helix-kit-agents` repository. That repository is intentionally left intact as a historical/self-host fallback, but HelixKit-managed agents should build and run this in-repo runtime.

## Local build

```bash
docker build -t helixkit-agent-runtime:local agent-runtime
```

Local Rails development defaults should point at that tag:

```bash
HELIXKIT_AGENT_IMAGE_DEFAULT=helixkit-agent-runtime:local
HELIXKIT_AGENT_INTERNAL_URL=http://host.docker.internal:3100
HELIXKIT_SANDBOX_HOST=local-docker-desktop
HELIXKIT_AGENT_PUBLISH_PORTS=1
HELIXKIT_AGENT_BACKUPS_ENABLED=false
```

## Runtime contract

HelixKit starts one container per hosted agent. The container listens on port `4000` and exposes:

- `GET /health` — unauthenticated liveness check
- `POST /trigger` — bearer-authenticated trigger endpoint

HelixKit mounts five Docker volumes:

- `/home/agent/identity` — canonical identity and memory, backed up by HelixKit/restic
- `/home/agent/.chaos` — chaos CLI session/config state
- `/home/agent/repo` — the Chaos working directory and repository
- `/home/agent/work` — durable agent-created working files
- `/home/agent/state` — private vendor credentials and other runtime state;
  deliberately excluded from HelixKit filesystem browsing

All five volumes survive runtime image replacement. The identity, Chaos, repo,
and work volumes are included in the hosted-agent restic backup set. Private
runtime state is deliberately excluded because it contains live provider
credentials; restored residents must reconnect subscriptions whose credentials
were stored there, including Anthropic.
Other container paths, including arbitrary files written directly under
`/home/agent` or `/tmp`, are ephemeral and may disappear when the runtime image
is refreshed.

When upgrading an older hosted agent, HelixKit copies an existing
container-layer `/home/agent/work` directory into the new work volume before it
removes the old container. This is a one-time compatibility migration; once the
volume exists, its contents are reused unchanged.

Identity and runtime infrastructure have separate ownership:

- identity, self-narrative, journals, and memories live under
  `/home/agent/identity`;
- subscription credentials live under `/home/agent/state` and are never copied
  into identity, the repository, or the Chaos home;
- current HelixKit operating instructions and API documentation ship with the
  image under `/usr/local/share/helixkit-agent`;
- runtime upgrades do not rewrite historical documentation files already
  present on an identity volume.

The Stop-journal hook script copied to `identity/automation/` is a deliberate
bounded exception retained so it remains visible in the hosting filesystem
browser. The script is runtime infrastructure; journal entries remain
agent-authored identity and memory.

HelixKit passes these env vars:

- `AGENT_ID` — stable UUID identity
- `AGENT_SLUG` — human-readable logging label
- `AGENT_PROVIDER`
- `AGENT_DEFAULT_MODEL`
- `TRIGGER_BEARER_TOKEN`
- `HELIXKIT_BEARER_TOKEN`
- `HELIXKIT_APP_URL`
- provider keys such as `ANTHROPIC_API_KEY` / `OPENAI_API_KEY`

The shim uses `AGENT_SLUG || AGENT_ID` for log labels, but reports `AGENT_ID` in `/health`.

The image also provides a small callback helper on `$PATH`:

```bash
printf '%s\n' 'message text' | helixkit-post-message CHAT_ID
cat <<'HELIXKIT_MESSAGE' | helixkit-post-message CHAT_ID
line one

line two with a literal $4.42 and `backticks`
HELIXKIT_MESSAGE
printf 'longer markdown' | helixkit-post-message CHAT_ID
printf 'generated image' | helixkit-post-message CHAT_ID --attach /tmp/image.png
printf 'caption' | helixkit-send-telegram daniel --attach /tmp/image.png
```

It reads `HELIXKIT_APP_URL` and `HELIXKIT_BEARER_TOKEN` from the environment
and posts an assistant message as the current agent. Prefer this helper in
triggered responses so agents do not have to reconstruct curl/JSON by hand.
Literal `\n` sequences in quoted message arguments are normalized to real
newlines before posting.

The authoritative in-container manual is:

```text
/usr/local/share/helixkit-agent/helixkit-api.md
```

It is built and rolled out with the helper programs it documents. Each
`helixkit-*` helper points to it from `--help`.

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
