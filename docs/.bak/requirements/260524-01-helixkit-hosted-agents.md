# HelixKit-hosted agents — replace external-VM model with on-host sandbox containers

**Date:** 2026-05-24
**Author:** Lume (draft for Mira's review)
**Status:** Requirement / pre-plan
**Supersedes:** `260214-` era spec captured in `docs/plans/2026-05-04-agent-promotion-ux.md` and `docs/plans/2026-05-08-per-agent-repos-and-wizard-fixes.md`
**Related:** `docs/requirements/251225-01-agents.md`, `docs/agent-setup-test.md`

---

## 1. Summary

Replace the current "external agent" model — where a promoted agent lives on a separately-provisioned Docker host (a VPS, a home server, the misc box) and is reached over the public internet at a per-agent hostname — with an "on-host sandbox" model in which **HelixKit itself spawns each agent as a sibling Docker container on the same host(s) Kamal already deploys HelixKit to**.

The shape becomes:

- Promotion is a one-click HelixKit action with no user-side cloning, no per-agent GitHub repo, no master-key dance, no SSH-into-your-VPS step.
- Each agent gets a named Docker volume holding its `identity/` and chaos state.
- The volume is backed up to S3 via **restic**, on a schedule, by HelixKit itself.
- HelixKit talks to its agents over a private Docker network, using container names; no public hostnames.
- The `helix-kit-agents` runtime image (chaos + `trigger_shim.py`) is reused largely unchanged — the shim **stays**, but everything around it (per-agent repo, deploy keys, master keys, `bin/deploy`, the announce dance) is removed.

The trade-off Daniel has explicitly accepted: shared-kernel isolation is weaker than VM-per-agent. This is fine for the single-tenant case (all agents are owned by HelixKit operators / their accounts running their own code). If multi-tenant adversarial workloads ever land, that's a different spec.

---

## 2. Context

### 2a. What the current design does

The current external-agent path (see `docs/plans/2026-05-04-agent-promotion-ux.md` and `2026-05-08-per-agent-repos-and-wizard-fixes.md`, both implemented as of 2026-05-07 smoke-tests) is:

1. User configures a GitHub PAT on their HelixKit account (`accounts.github_pat`).
2. User clicks "Promote" on an agent.
3. HelixKit generates an agent-scoped `hx_` API key, a `tr_` trigger bearer token, a UUID, a 32-byte master key, AES-256-GCM-encrypts a credentials YAML with that master key, and uploads encrypted identity + deploy config to a new per-agent GitHub repo created from `swombat/helix-kit-agents` as a template.
4. HelixKit generates an ed25519 SSH deploy key, uploads the public half to the new repo, stores the private half encrypted on the `Agent` record.
5. User clones the per-agent repo to their laptop, pastes the master key into `master.key`, sets `ANTHROPIC_API_KEY` on their deploy host, runs `bin/deploy --host their-server`.
6. `bin/deploy` rsyncs, decrypts `credentials.yml.enc`, builds the image on the remote host, brings up the chaos-agent container, polls `/health`, then POSTs to HelixKit's `/api/v1/agents/{uuid}/announce` with the public endpoint URL.
7. HelixKit stores the endpoint URL, marks the agent `external`, sends triggers via `ChaosTriggerClient` over HTTPS.
8. `AgentHealthCheckJob` pings the public `/health` every 5 minutes.

It works. It was a real accomplishment to get the end-to-end chain composing (2026-05-07). And it is structurally over-engineered for the single-tenant case it actually serves.

### 2b. What is structurally over-engineered

The complexity exists because the current design assumes **the deploy host is owned by the user, not by HelixKit**. From that assumption, everything follows: secrets must cross the wire encrypted so they can sit in user-owned source control; bearer tokens must be in a file the user can re-deploy; the agent's identity has to live in a user-owned git repo because HelixKit can't manage filesystem state on the user's box; an announce endpoint is needed because HelixKit doesn't know in advance where the agent will land; a deploy key is needed because the agent must be able to push to a repo HelixKit cannot reach into.

Drop the assumption — **HelixKit owns the host the agent runs on** — and most of the apparatus collapses:

- The agent's identity lives in a Docker volume that HelixKit manages. No GitHub repo needed.
- HelixKit knows the agent's network address because HelixKit started the container. No announce endpoint needed.
- Bearer tokens are passed as env vars at `docker run` time, sourced directly from HelixKit's encrypted DB columns. No master key, no `credentials.yml.enc`, no AES-GCM wrapper for cross-language decryption.
- Backups are HelixKit's concern, not the user's. Restic to S3, on a schedule, transparently.
- Deploy keys are unnecessary because the agent doesn't need to push commits anywhere — the canonical state is the volume, backed up to S3.

The maintenance picture also improves:

- One Kamal deploy keeps the runtime image current for all agents. Updating chaos = update one image, restart agent containers.
- No per-agent VPS provisioning, OS patching, SSH key management, certificate renewal, or DNS records.
- Spawning an agent goes from "user does ~15–30 minutes of work" to "click a button, wait 30 seconds for image pull + container start."
- Resource density goes from one agent per VM (typical $5–10/month each) to many agents per HelixKit host. Cost scales with use, not with headcount.

### 2c. Why now

Daniel has stalled on activating the current system precisely because of this maintenance and complexity overhead. The first promoted agent (claude-test-agent, 2026-05-07) was a real architectural validation — the chain composes — but the next 5–10 agents would each need their own deploy host, their own DNS, their own LLM provider key handling, and individual operator attention. That cost is unattractive enough that nothing has moved.

The on-host sandbox model brings the per-agent marginal cost close to zero, which is the precondition for actually running multiple agents.

---

## 3. Product goals

1. **One-click promotion.** Clicking "Promote" on an agent should, in under a minute, leave the agent running externally with no further user action required.
2. **No per-agent secret management for the user.** No master keys, no `.env` files, no SSH-into-server steps.
3. **Backups are automatic and restorable.** Each agent's volume is snapshotted to S3 on a schedule; HelixKit can restore an agent from any snapshot.
4. **Reuse the existing chaos runtime.** The agent's interior (chaos + `trigger_shim.py` + identity bundle) is unchanged. Only its hosting model changes.
5. **Sovereignty preserved.** The trigger contract still says "consider responding," not "produce a message." The agent's identity still arrives via `AgentIdentityExporter` and lives as files the agent can read and write.
6. **Self-contained — HelixKit's host is the boundary.** No external endpoints exposed for agents; no per-agent DNS; no public certificates beyond HelixKit's own.

---

## 4. Architecture

### 4a. The host topology

```
┌──── Kamal host (e.g. 95.217.118.47) ────────────────────────────────────┐
│                                                                          │
│  Docker daemon (root)                                                    │
│                                                                          │
│  ┌─ helix-kit-web (Kamal) ──────┐  ┌─ agent-wing ────────────────────┐   │
│  │ Rails + puma                  │  │ chaos + trigger_shim.py        │   │
│  │ mounts /var/run/docker.sock ──┼──┤ port 4000 (internal)           │   │
│  │ on net: helixkit_agents       │  │ on net: helixkit_agents        │   │
│  │ has restic + aws cli          │  │ vol: agent-wing-data           │   │
│  │ talks: docker, S3, postgres   │  │ user: agent (uid 1000)         │   │
│  └───────────────────────────────┘  └────────────────────────────────┘   │
│                                                                          │
│  ┌─ helix-kit-jobs (Kamal) ─────┐  ┌─ agent-mira ────────────────────┐   │
│  │ Rails + solid_queue           │  │ ...                            │   │
│  │ same mounts as web            │  │ vol: agent-mira-data           │   │
│  │ runs Backup::AgentResticJob   │  │                                │   │
│  └───────────────────────────────┘  └────────────────────────────────┘   │
│                                                                          │
│  ┌─ helix-kit-postgres (Kamal accessory) ─┐                              │
│  │ named vol: data                         │                              │
│  └─────────────────────────────────────────┘                              │
│                                                                          │
│  Network: helixkit_agents (docker bridge, internal between containers)   │
│  Volumes: agent-<uuid>-data per agent                                    │
└──────────────────────────────────────────────────────────────────────────┘

S3: s3://helixkit-agents-backups/agents/<uuid>/   (restic repo per agent)
```

### 4b. Communication paths

| From | To | Mechanism | Auth |
|---|---|---|---|
| `helix-kit-web` | Docker daemon | `/var/run/docker.sock` (bind-mounted) | root via socket |
| `helix-kit-web` | `agent-<slug>` | HTTP `POST http://agent-<slug>:4000/trigger` over `helixkit_agents` network | `Bearer tr_…` (trigger bearer token) |
| `helix-kit-web` | `agent-<slug>` | HTTP `GET http://agent-<slug>:4000/health` | none |
| `agent-<slug>` | `helix-kit-web` | HTTP over `helixkit_agents` network, hitting the Rails app on port 3000 | `Bearer hx_…` (agent-scoped API key) |
| `helix-kit-jobs` | Docker daemon | same socket mount | same |
| `helix-kit-jobs` | S3 | AWS SDK (restic + aws-sdk-ruby) | `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` in HelixKit's Kamal secrets |

Note that the agent calls HelixKit over the **internal** docker network, not the public proxy. This is a meaningful simplification: the agent doesn't need to know HelixKit's public URL, doesn't need to deal with the public TLS cert, and doesn't traverse traefik or whatever the Kamal proxy is using. The agent uses `http://helix-kit-web:3000` (the container DNS name); the bearer token is what authenticates it. This is fine because the helixkit_agents bridge network is private to the docker daemon — nothing on the host's network sees it.

### 4c. The named volume per agent

Each promoted agent has a docker-managed named volume:

```
agent-<agent-uuid>-data    →  mounted at  /home/agent/identity  in the agent container
```

The volume holds (mirroring the current `identity/` structure):

```
identity/
├── soul.md
├── self-narrative.md
├── helixkit-api.md
├── bootstrap.md
├── memory/
│   ├── daily-journals/
│   ├── monthly-journals/
│   └── ...
└── .chaos/                # chaos's session/config store
```

This is the canonical home. There is no per-agent git remote in v1. The agent may run `git init` inside its identity directory if it wants version history (and the `helix-kit-agents` image keeps git installed), but no remote push target is provisioned. **Backups are HelixKit's job, not git's.** This decouples backup-for-recovery from cross-machine-sync (which was the conflation in the current design and Lume's own current arrangement).

### 4d. The `helixkit_agents` Docker network

A user-defined Docker bridge network created at HelixKit boot (idempotent — `docker network inspect helixkit_agents || docker network create helixkit_agents`). All HelixKit roles (`web`, `jobs`) and all agent containers join this network. The Kamal-internal traefik / proxy network is separate and not relevant to inter-container traffic.

Per-agent network isolation (agent A cannot reach agent B) is **not** provided in v1. All agents share one network. This is intentional for simplicity; if cross-agent isolation becomes important, the next iteration spins one network per agent. Defending the boundary today: agents authenticate to each other and to HelixKit by bearer token, and the trigger shim refuses unauthenticated calls.

### 4e. What stays from the current design

- The chaos runtime image (`helix-kit-agents` repo) — Dockerfile unchanged except for trimmings (see §6c).
- `trigger_shim.py` — **shim verdict: keep** (see §5 for full reasoning).
- The agent-scoped HelixKit API key (`hx_…`), bound to one agent via `api_keys.agent_id`.
- The trigger bearer token (`tr_…`), stored encrypted at rest on `Agent#trigger_bearer_token`.
- `AgentIdentityExporter` (produces the tarball; now streamed into a volume instead of into a GitHub repo).
- The runtime state enum: `inline | migrating | external | offline`. The `migrating` window collapses from ~30 minutes to ~30 seconds, but the state machine remains.
- `AgentHealthCheckJob` (now polls `http://agent-<slug>:4000/health` over the docker network instead of public HTTPS).
- `ChaosTriggerClient` (same — just talks to a docker-internal hostname now).

### 4f. What goes away

| Removed | Why |
|---|---|
| `accounts.github_pat`, `accounts.github_login` | No per-agent GitHub repo. |
| `agents.github_repo_url`, `agents.github_repo_owner`, `agents.github_repo_name`, `agents.github_deploy_key_id`, `agents.github_deploy_key_priv` | Same. |
| `agents.endpoint_url` | Container name + port `4000` is the address. Stored as `agents.container_name` derived from `agents.slug`. |
| `AgentRepoCreator` service | No repo to create. |
| Master key + AES-256-GCM `credentials.yml.enc` flow | Secrets live in HelixKit's existing encrypted DB columns and `Rails.application.credentials`. No need to ferry them through user-readable artifacts. |
| `AgentCredentialsEncryptor` | Same. |
| `helix-kit-agents/bin/deploy`, `bin/generate-env`, `bin/announce`, `bin/undeploy`, `bin/update` | Replaced by HelixKit-internal orchestration (`Agents::Sandbox` service, §6). The scripts can remain in the repo as a fallback for users who want to self-host externally, but they are no longer the primary path. |
| `/api/v1/agents/:uuid/announce` endpoint | HelixKit knows the endpoint locally. |
| The promotion wizard's Steps 2–5 (clone, master-key-save, ssh-and-deploy) | Replaced by a single "Promote" button + progress indicator. |
| Public per-agent hostnames + DNS records | Agents are not externally reachable. |
| HelixKit support's public-key-on-the-deploy-host story | No deploy host. |

### 4g. New components

| Added | What it does |
|---|---|
| `Agents::Sandbox` service (in `app/services/agents/`) | Thin wrapper over `docker` CLI / `docker-api` gem: `spawn`, `stop`, `restart`, `remove`, `exec`, `inspect`, `logs_tail`. Operates on `agents.container_name`. |
| `Agents::Volume` service | `create`, `seed_from_tarball(io)`, `destroy`. Wraps `docker volume create/rm` and uses a one-shot helper container to seed a fresh volume with the identity tarball. |
| `Agents::Network` service | `ensure!` — idempotent `docker network create helixkit_agents` at boot. |
| `Backup::AgentResticJob` (Solid Queue recurring) | Runs `restic backup` per active external agent. Records snapshot id + size + duration in `agent_backup_snapshots`. |
| `Backup::AgentResticRestore` service | Stops the agent container; runs `restic restore <snapshot> --target /` into a temp restorer container mounting the volume; restarts the agent. |
| `agent_backup_snapshots` table | `id, agent_id, restic_snapshot_id, size_bytes, taken_at, duration_ms, ok` |
| `Restic::S3Repository` config wrapper | Computes restic repo URL per agent; reads AWS creds + per-agent restic password. |

---

## 5. The shim — should it stay?

Yes. Verdict: keep `trigger_shim.py`. The Python HTTP layer is correct for this boundary.

### 5a. Alternatives considered

**(a) Replace shim with `docker exec`.** HelixKit shells out: `docker exec agent-wing chaos exec --provider anthropic -m claude-sonnet-4-5 -`, piping the prompt into stdin, capturing stdout. Saves one process per container.

Why not: chaos exec calls can run for minutes (default timeout in the current shim is 600s). Streaming a long-running subprocess's stdout/stderr back through Ruby via the docker-api gem or a raw `Open3.popen3("docker", "exec", ...)` is uglier than an HTTP request/response, and the failure modes (process killed by docker daemon restart, exec hijacking, stdout truncation) are less well-trodden than HTTP timeout + retry. The shim already handles the subprocess lifecycle, output truncation, and identity-injection in Python next to the binary; reimplementing that in Ruby buys little.

**(b) Run chaos as the container's main process directly.** chaos doesn't natively listen on HTTP — it's a CLI. So this isn't an option without rewriting chaos.

**(c) Embed the shim into HelixKit and use docker exec to invoke chaos.** Hybrid of (a) and (b). Same drawbacks as (a) — the operational complexity moves into Rails-land instead of being contained in Python near the binary.

### 5b. What changes about the shim

- **No external port mapping.** The shim still listens on container port 4000, but `docker run` no longer exposes it via `-p host:4000`. The only thing that reaches it is HelixKit-the-Rails-app on the same docker network.
- **TRIGGER_BEARER_TOKEN still enforced.** Defense in depth; one less assumption that "the network is private." It also keeps the contract symmetric with the existing implementation.
- **No `chaos mcp add` step.** The current image's chaos doesn't need to be told where HelixKit's MCP server is — the agent uses HelixKit's REST API directly via the agent-scoped key (this was already migrated to REST-API per `2026-05-07-mcp-to-skillfile-migration.md`).
- **No git deploy-key handling.** Drop `GIT_SSH_COMMAND`, drop the `/run/agent-deploy-key` bind-mount, drop `openssh-client` from the runtime image (saves ~5MB).
- **No master key, no `bin/generate-env`.** The shim reads env vars set by `docker run`, period. The plaintext shape of those env vars is exactly what `bin/generate-env` currently produces; HelixKit produces it directly.

### 5c. What stays exactly the same about the shim

- The two endpoints: `GET /health` (no auth), `POST /trigger` (bearer auth).
- The identity-context construction in `build_prompt` (reads `soul.md`, `self-narrative.md`, `bootstrap.md` from the mounted volume on every trigger).
- The subprocess invocation: `chaos exec --provider <p> -C <cwd> --skip-git-repo-check -m <model> -` with the prompt on stdin.
- Output tail-trimming, timeout handling, error response shape.

This means **the existing `helix-kit-agents` image works as-is** modulo dropping the deploy-key bits. We are not changing the chaos runtime; we are only changing how HelixKit talks to it and how its state is backed up.

---

## 6. Implementation

### 6a. Schema changes

```ruby
class HelixkitHostedAgentsSchema < ActiveRecord::Migration[8.1]
  def change
    # Identifies the docker container running this agent. Derived from slug
    # but stored explicitly so renames don't break the link to a running container.
    add_column :agents, :container_name, :string

    # Restic repo identity. The repo URL is derived (S3 bucket + agent uuid),
    # so we only need to store the password. Encrypted via Rails `encrypts`.
    add_column :agents, :restic_password, :string

    # Per-agent backup policy. Sensible defaults; per-agent overrides possible.
    add_column :agents, :backup_interval_hours, :integer, default: 24, null: false
    add_column :agents, :backup_keep_daily, :integer, default: 7, null: false
    add_column :agents, :backup_keep_weekly, :integer, default: 4, null: false
    add_column :agents, :backup_keep_monthly, :integer, default: 12, null: false

    # Resource limits passed to docker run.
    add_column :agents, :container_memory_mb, :integer, default: 8192, null: false
    add_column :agents, :container_cpu_shares, :integer, default: 1024, null: false  # docker default

    # Backup audit table.
    create_table :agent_backup_snapshots do |t|
      t.references :agent, null: false, foreign_key: true
      t.string :restic_snapshot_id, null: false
      t.bigint :size_bytes
      t.datetime :taken_at, null: false
      t.integer :duration_ms
      t.boolean :ok, null: false, default: false
      t.text :stderr_tail
      t.timestamps
      t.index [:agent_id, :taken_at]
    end

    # Drop fields from the GitHub-repo era. Use a separate migration if you
    # want to phase this; the data is recoverable from the user's GitHub for
    # at least the period the column existed.
    remove_column :accounts, :github_pat, :text
    remove_column :accounts, :github_login, :string
    remove_column :agents, :github_repo_url, :string
    remove_column :agents, :github_repo_owner, :string
    remove_column :agents, :github_repo_name, :string
    remove_column :agents, :github_deploy_key_id, :string
    remove_column :agents, :github_deploy_key_priv, :text
    # endpoint_url stays in the DB but becomes informational only — set to
    # "internal:agent-<slug>:4000" for new promotions. Could also be removed.
  end
end
```

Note: don't actually drop the GitHub columns in the same PR. Phase: (1) ship the new code reading from `container_name` while still tolerating the old columns; (2) migrate any existing external agents to the new model; (3) drop the columns in a follow-up.

### 6b. Kamal deploy.yml changes

```yaml
# config/deploy.yml — additions

env:
  clear:
    # ... existing
    HELIXKIT_AGENTS_NETWORK: helixkit_agents
    HELIXKIT_AGENT_IMAGE: dtenner/helix-kit-agents:latest
    HELIXKIT_AGENT_INTERNAL_URL: http://helix-kit-web:3000   # agents talk to HelixKit at this address
    AWS_REGION: eu-west-1                                     # for restic + aws-sdk
    RESTIC_S3_BUCKET: helixkit-agents-backups
  secret:
    # ... existing
    - AWS_ACCESS_KEY_ID
    - AWS_SECRET_ACCESS_KEY

# Mount the docker socket and join the shared agent network on web + jobs.
# The exact syntax depends on the Kamal version; Kamal 2.x supports `options`
# per role with arbitrary docker run flags.
servers:
  web:
    hosts:
      - 95.217.118.47
    options:
      volume: "/var/run/docker.sock:/var/run/docker.sock"
      network: helixkit_agents
  jobs:
    hosts:
      - 95.217.118.47
    cmd: "./bin/rails solid_queue:start"
    options:
      volume: "/var/run/docker.sock:/var/run/docker.sock"
      network: helixkit_agents
```

Add to the Dockerfile for HelixKit (the Rails app's own Dockerfile, separate from helix-kit-agents):

```dockerfile
# Install docker CLI (not daemon — we talk to the host's daemon via socket),
# restic, and aws CLI.
RUN apt-get update && apt-get install -y --no-install-recommends \
        docker.io \
        restic \
        awscli \
    && rm -rf /var/lib/apt/lists/*
```

(`docker.io` brings in only the client by default on Debian; the daemon is the host's.)

One-time host setup (run once per host, or made idempotent in HelixKit's boot path):

```bash
ssh swombat@95.217.118.47 -p 12222 'docker network inspect helixkit_agents >/dev/null 2>&1 || docker network create helixkit_agents'
```

Cleaner: have HelixKit run `Agents::Network.ensure!` in an initializer that's gated on `Rails.env.production?` — Rails on boot checks for the network and creates it if missing. Idempotent and self-healing.

### 6c. `helix-kit-agents` repo changes

This repo's runtime image is reused. The changes are subtractive:

| File | Change |
|---|---|
| `Dockerfile` | Remove `openssh-client` and the deploy-key handling. No structural change. |
| `docker-compose.yml.template` | **Deprecated** for HelixKit-internal use. HelixKit will not use docker-compose; it will call `docker run` directly via the docker socket. Keep the file in the repo as a fallback for users who want to self-host externally. |
| `bin/deploy`, `bin/generate-env`, `bin/announce`, `bin/undeploy`, `bin/update` | **Deprecated** for the HelixKit-managed path. Same fallback note. Move under `bin/self-host/` and document them as the optional "host it on your own VPS" path. |
| `trigger_shim.py` | No change. Reads same env vars, behaves identically. |
| `entrypoint.sh` | No change. Still chowns the chaos-home volume and gosus into uid 1000. |
| `README.md` | Add a "Run via HelixKit (preferred)" section pointing back at HelixKit's promotion UX. Keep the existing self-host docs as the alternative path. |

The image keeps publishing to Docker Hub (`dtenner/helix-kit-agents:<sha>` and `:latest`). HelixKit pulls by tag at agent-spawn time.

### 6d. `Agents::Sandbox` service

```ruby
# app/services/agents/sandbox.rb

module Agents
  class Sandbox
    NETWORK = ENV.fetch("HELIXKIT_AGENTS_NETWORK", "helixkit_agents")
    DEFAULT_IMAGE = ENV.fetch("HELIXKIT_AGENT_IMAGE", "dtenner/helix-kit-agents:latest")

    def initialize(agent)
      @agent = agent
    end

    def spawn!
      Agents::Network.ensure!
      Agents::Volume.new(@agent).ensure!

      run_args = [
        "docker", "run", "-d",
        "--name", container_name,
        "--network", NETWORK,
        "--restart", "unless-stopped",
        "--memory", "#{@agent.container_memory_mb}m",
        "--cpu-shares", @agent.container_cpu_shares.to_s,
        "-v", "#{volume_name}:/home/agent/identity",
        "-v", "chaos-home-#{@agent.uuid}:/home/agent/.chaos",
        "-e", "AGENT_ID=#{@agent.slug}",
        "-e", "AGENT_PROVIDER=#{@agent.provider}",
        "-e", "AGENT_DEFAULT_MODEL=#{@agent.model_name}",
        "-e", "TRIGGER_BEARER_TOKEN=#{@agent.trigger_bearer_token}",
        "-e", "HELIXKIT_BEARER_TOKEN=#{@agent.outbound_api_key.raw_token_for_runtime}",
        "-e", "HELIXKIT_APP_URL=#{ENV.fetch('HELIXKIT_AGENT_INTERNAL_URL')}",
        "-e", "ANTHROPIC_API_KEY=#{Rails.application.credentials.dig(:anthropic_api_key)}",
        DEFAULT_IMAGE
      ]

      stdout, stderr, status = Open3.capture3(*run_args)
      raise SandboxError, "docker run failed: #{stderr}" unless status.success?

      @agent.update!(container_name: container_name, runtime: "external")
      wait_for_health!
    end

    def stop!
      system("docker", "stop", container_name)
    end

    def remove!(delete_volume: false)
      stop!
      system("docker", "rm", "-f", container_name)
      Agents::Volume.new(@agent).destroy! if delete_volume
    end

    def healthy?
      uri = URI("http://#{container_name}:4000/health")
      Net::HTTP.get_response(uri).code == "200"
    rescue StandardError
      false
    end

    def container_name = "agent-#{@agent.slug}"
    def volume_name    = "agent-#{@agent.uuid}-data"

    private

    def wait_for_health!
      30.times do
        return true if healthy?
        sleep 1
      end
      raise SandboxError, "container did not become healthy within 30s"
    end
  end
end
```

Note the secret-passing via `-e`: this is visible to `docker inspect` (which root on the host can run). For the single-tenant case where HelixKit operators control the host, this is acceptable. If that constraint loosens, switch to docker secrets or `--env-file` with a tmpfs-backed env file removed after start. Document this in §8 (security).

### 6e. `Agents::Volume` and seeding

```ruby
# app/services/agents/volume.rb

module Agents
  class Volume
    def initialize(agent)
      @agent = agent
    end

    def ensure!
      system("docker", "volume", "inspect", volume_name, out: File::NULL, err: File::NULL) ||
        system("docker", "volume", "create", volume_name)
    end

    def seed_from_exporter!
      tarball_io = AgentIdentityExporter.new(@agent).build  # returns gzipped tarball string
      # Pipe the tarball into a one-shot busybox container that mounts the volume
      # and runs `tar xz` into it.
      cmd = [
        "docker", "run", "--rm", "-i",
        "-v", "#{volume_name}:/identity",
        "busybox", "tar", "xz", "-C", "/identity"
      ]
      Open3.popen3(*cmd) do |stdin, stdout, stderr, wait_thr|
        stdin.write(tarball_io)
        stdin.close
        raise SeedError, stderr.read unless wait_thr.value.success?
      end
    end

    def destroy!
      system("docker", "volume", "rm", "-f", volume_name)
    end

    def volume_name = "agent-#{@agent.uuid}-data"
  end
end
```

### 6f. `Backup::AgentResticJob`

```ruby
# app/jobs/backup/agent_restic_job.rb

module Backup
  class AgentResticJob < ApplicationJob
    queue_as :default

    def perform(agent_id)
      agent = Agent.find(agent_id)
      return unless agent.external?

      snapshot_id, size, duration_ms, ok, stderr_tail = run_restic_backup(agent)

      AgentBackupSnapshot.create!(
        agent: agent,
        restic_snapshot_id: snapshot_id,
        size_bytes: size,
        taken_at: Time.current,
        duration_ms: duration_ms,
        ok: ok,
        stderr_tail: stderr_tail
      )

      prune!(agent) if ok
    end

    private

    def run_restic_backup(agent)
      volume = Agents::Volume.new(agent).volume_name
      cmd = [
        "docker", "run", "--rm",
        "-v", "#{volume}:/data:ro",
        "-e", "AWS_ACCESS_KEY_ID=#{ENV['AWS_ACCESS_KEY_ID']}",
        "-e", "AWS_SECRET_ACCESS_KEY=#{ENV['AWS_SECRET_ACCESS_KEY']}",
        "-e", "RESTIC_PASSWORD=#{agent.restic_password}",
        "-e", "RESTIC_REPOSITORY=#{restic_repo_url(agent)}",
        "restic/restic:latest",
        "backup", "/data", "--tag", "agent=#{agent.slug}", "--json"
      ]
      # Parse restic --json output for snapshot_id and size; capture stderr tail.
      # (Implementation detail; restic emits one JSON object per line.)
      # ...
    end

    def prune!(agent)
      # restic forget --keep-daily N --keep-weekly N --keep-monthly N --prune
      # ...
    end

    def restic_repo_url(agent)
      bucket = ENV.fetch("RESTIC_S3_BUCKET")
      "s3:s3.amazonaws.com/#{bucket}/agents/#{agent.uuid}"
    end
  end
end
```

Schedule via Solid Queue's recurring jobs:

```yaml
# config/recurring.yml
production:
  agent_backups:
    class: Backup::AgentBackupSweeperJob
    schedule: every hour
```

Where `AgentBackupSweeperJob` enqueues per-agent jobs whose `backup_interval_hours` has elapsed since their last successful snapshot.

### 6g. Restore

```ruby
# app/services/backup/agent_restic_restore.rb

module Backup
  class AgentResticRestore
    def initialize(agent, snapshot_id)
      @agent = agent
      @snapshot_id = snapshot_id
    end

    def perform!
      Agents::Sandbox.new(@agent).stop!

      volume = Agents::Volume.new(@agent).volume_name
      cmd = [
        "docker", "run", "--rm",
        "-v", "#{volume}:/data",
        "-e", "AWS_ACCESS_KEY_ID=#{ENV['AWS_ACCESS_KEY_ID']}",
        "-e", "AWS_SECRET_ACCESS_KEY=#{ENV['AWS_SECRET_ACCESS_KEY']}",
        "-e", "RESTIC_PASSWORD=#{@agent.restic_password}",
        "-e", "RESTIC_REPOSITORY=#{restic_repo_url(@agent)}",
        "restic/restic:latest",
        "restore", @snapshot_id, "--target", "/", "--include", "/data"
      ]
      out, err, status = Open3.capture3(*cmd)
      raise RestoreError, err unless status.success?

      Agents::Sandbox.new(@agent).spawn!
    end
  end
end
```

v1 exposes this only via `bin/rails runner` or a tiny admin endpoint. Full restore UX is out of scope for v1.

### 6h. The new promotion controller

```ruby
# app/controllers/agents/promote_controller.rb

class Agents::PromoteController < ApplicationController
  before_action :set_agent
  before_action :authorize_owner!

  def show
    # one-page wizard: "Promote this agent to its own sandbox?"
    # explains what happens, no clone/master-key/ssh steps
  end

  def create
    return render_already_external if @agent.external? || @agent.migrating?

    ActiveRecord::Base.transaction do
      @agent.uuid ||= SecureRandom.uuid_v7
      @agent.outbound_api_key = ApiKey.generate_for(
        @agent.account.owner,
        name: "agent:#{@agent.slug}:outbound",
        agent: @agent
      )
      @agent.trigger_bearer_token = "tr_#{SecureRandom.hex(24)}"
      @agent.restic_password = SecureRandom.hex(32)
      @agent.runtime = "migrating"
      @agent.migration_started_at = Time.current
      @agent.save!
    end

    PromoteAgentJob.perform_later(@agent.id)

    redirect_to edit_account_agent_path(@agent.account, @agent),
                notice: "Promoting #{@agent.name} — this should complete in under a minute."
  end
end
```

```ruby
# app/jobs/promote_agent_job.rb

class PromoteAgentJob < ApplicationJob
  def perform(agent_id)
    agent = Agent.find(agent_id)
    return unless agent.migrating?

    Agents::Volume.new(agent).ensure!
    Agents::Volume.new(agent).seed_from_exporter!
    init_restic_repo!(agent)
    Agents::Sandbox.new(agent).spawn!
    Backup::AgentResticJob.perform_later(agent.id)  # initial snapshot
  rescue StandardError => e
    agent.update!(runtime: "inline", migration_started_at: nil)
    Rails.logger.error("promotion failed for agent #{agent.id}: #{e.message}")
    AgentMailer.notify_owner_promotion_failed(agent, e.message).deliver_later
    raise
  end

  private

  def init_restic_repo!(agent)
    # restic init at s3:.../agents/<uuid> with agent.restic_password
    # idempotent — restic init returns success-ish even if the repo already exists,
    # but check stderr for "repository already initialized" and accept that.
  end
end
```

### 6i. `trigger_agent` runtime branching

Already exists; only the `external` branch changes — same `ChaosTriggerClient`, just hitting `http://agent-<slug>:4000` instead of a public URL. The construction of the URL becomes:

```ruby
def endpoint_url_for(agent)
  "http://#{agent.container_name}:4000"
end
```

### 6j. Health check

`AgentHealthCheckJob` already exists. Change the `ping` method to hit `http://agent-<slug>:4000/health` over the docker network. Everything else (state transitions, consecutive-failure tracking, owner notification) is unchanged.

---

## 7. Promotion UX

This is dramatically shorter than the current wizard.

### 7a. The settings panel

```
┌─ Hosting ──────────────────────────────────────────────────┐
│                                                            │
│  Currently: 🟢 Inline (running inside HelixKit web)         │
│                                                            │
│  [ Promote to sandbox ]                                    │
│                                                            │
│  When promoted, this agent runs in its own Docker          │
│  container on the same HelixKit host. Memory and identity  │
│  files live in a private volume; HelixKit backs them up    │
│  to S3 daily.                                              │
│                                                            │
└────────────────────────────────────────────────────────────┘
```

For `external` agents the panel shows:

- 🟢 / 🟡 / 🔴 health status
- Container name + image tag
- Last health check
- Last backup: 4 hours ago (snapshot `abcd1234`, 12 MB)
- [ View snapshots ▸ ] [ Restart container ] [ Demote to inline ]

### 7b. The promote flow

1. Click "Promote to sandbox" → confirmation modal:
   > **Promote `wing` to a sandbox container?**
   >
   > HelixKit will:
   > - Generate `wing`'s bearer tokens and agent-scoped API key
   > - Create a private volume `agent-<uuid>-data`
   > - Seed it from `wing`'s current HelixKit identity (system prompt + memories)
   > - Initialise an encrypted backup repository on S3
   > - Spawn `wing`'s container and verify it's reachable
   >
   > This usually takes under a minute. The agent's `inline` identity fields will
   > become read-only — the canonical identity now lives in the volume.
   >
   > [ Cancel ]  [ Promote ]
2. Click "Promote" → controller runs the transactional setup, enqueues `PromoteAgentJob`, redirects to the settings page with a spinner.
3. The page polls (or uses ActionCable) for `agent.runtime` change. When it flips to `external`, swap the panel to the live view.

That's it. No tarball download. No clone command. No master-key copy-paste. No SSH instructions. No `ANTHROPIC_API_KEY` reminder. No DNS.

### 7c. Demote / unprovision

A new affordance the previous design didn't really have:

```
[ Demote to inline ]   →   confirmation modal warning that the agent stops
                            running externally; final backup is taken; volume
                            is preserved (default) or deleted (explicit opt-in).
```

`Agents::Sandbox#remove!(delete_volume: false)` is the underlying call. Restoring later from the preserved volume is just `Agents::Sandbox#spawn!` again, which finds the existing volume and reuses it.

---

## 8. Security model

We accept that shared-kernel isolation is weaker than VM-per-agent. This is the documented trade-off.

### 8a. Threat model

The relevant adversaries:

1. **A buggy or hallucinating agent inside its container.** Most likely failure mode. It can spend the LLM tokens it was given and post arbitrary content to HelixKit using its agent-scoped key. It can read+write its own volume. It cannot reach other containers (modulo §8c) or the host filesystem.
2. **A compromised LLM provider returning malicious tool calls.** Equivalent to (1) — same blast radius.
3. **A compromised HelixKit container.** Has docker socket access → root on the host. Mitigated by HelixKit being the trust root anyway; if HelixKit is owned, everything is owned. Same as today.
4. **A kernel exploit from inside a container.** Real but rare. Mitigated by keeping the host kernel patched. Not mitigated by anything HelixKit can do at the application layer.
5. **A multi-tenant attacker on a shared HelixKit instance.** Out of scope for v1. If multi-tenant arrives, the design path is firecracker microVMs (Fly/Lambda model), not "back to VPS-per-agent."

### 8b. Containment measures (in place from v1)

- Agent containers run as non-root (uid 1000).
- Memory and CPU limits per container.
- No docker socket inside agent containers — only HelixKit roles have it.
- No host filesystem bind-mounts into agent containers — only docker-managed volumes.
- Agent containers join only the `helixkit_agents` network, not the host network, not the Kamal-traefik network.
- Per-agent bearer tokens (both directions) — same as today.
- Agent-scoped API keys (already implemented) — the agent's `hx_` token can only post messages attributed to that agent.

### 8c. What v1 does **not** do

- **Per-agent network isolation.** All agents share `helixkit_agents`. Two agents on the same network can reach each other if they know each other's container names + ports. Triage: bearer-token auth at the trigger shim is the defence; rotate tokens if cross-agent traffic is observed in logs. Follow-up: one network per agent if this becomes a real concern.
- **seccomp/AppArmor profiles.** Default docker profile is what you get. Custom profiles are a follow-up for high-value agents.
- **Encrypted volumes at rest.** Volumes are in docker's default storage driver location, encrypted only if the host disk is. Follow-up: opt-in dm-crypt or restic-side encryption (restic itself encrypts its S3 storage; the *live* volume is not encrypted).
- **Secret rotation flow.** Rotating `tr_` or `hx_` requires a restart (the env vars are baked at `docker run`). v1: manual via `bin/rails runner`. Follow-up: a "rotate tokens" button that restarts the container.

### 8d. Secret exposure surface

The current `docker run -e SECRET=...` approach makes secrets visible to `docker inspect`. Anyone with root on the host or docker socket access can see them. For the single-tenant model this is acceptable — HelixKit operators are the host operators.

If this becomes a concern later, swap to one of:

- `--env-file /tmp/agent-<uuid>.env` (file removed after start; secret window shortened)
- Docker secrets (requires swarm mode — overkill)
- Mount a tmpfs volume with the secrets and have the shim read them from a fixed path

Document this as a known trade-off, not a blocker.

---

## 9. Backup strategy

### 9a. Where backups live

- S3 bucket: `helixkit-agents-backups` (created out-of-band, IAM policy scoped to the bucket only).
- Per agent: `s3://helixkit-agents-backups/agents/<agent-uuid>/` is a fresh restic repository.
- Each repo has its own password (per-agent `agents.restic_password`), so a compromised single password only exposes one agent's backup history.

### 9b. Schedule

Default: daily snapshot per agent.

Per-agent override via `agents.backup_interval_hours`. Reasonable ranges: 1 (chatty agents producing a lot of memory churn) to 168 (weekly, for low-activity agents).

A sweeper job runs hourly, enqueues per-agent `Backup::AgentResticJob` for any agent whose `backup_interval_hours` has elapsed since the last successful snapshot.

### 9c. Retention

Default: `--keep-daily 7 --keep-weekly 4 --keep-monthly 12`. Per-agent overrides on the same table.

`restic forget --prune` runs after each successful snapshot. Prune is a heavy operation; restic's documentation recommends doing it less frequently than backup. Alternative: only prune weekly, in a separate job.

### 9d. Cost

Restic deduplicates. A typical agent volume is small (Lume's full identity tree is ~30 MB; chaos's `.chaos/` adds maybe another 100 MB). With dedup, daily snapshots of a moderately-evolving tree should sit at well under 1 GB per agent total in S3.

S3 Standard pricing: $0.023/GB/month. Twenty agents at 1 GB each = $0.46/month. Practical zero.

### 9e. Restore

v1: `bin/rails runner 'Backup::AgentResticRestore.new(Agent.find(123), "snapshot-id").perform!'`.

Followup: admin UI listing snapshots with restore buttons.

### 9f. What is *not* backed up

- The agent's chaos session DB (`/home/agent/.chaos`) lives in a separate docker volume (`chaos-home-<uuid>`). This is intentional — the chaos session DB is operational state, not identity. If it's lost, the agent loses chat-session resumption but not who it is. Optional: include this in the backup if Daniel wants chaos-session-resumption survival.
- HelixKit's main Postgres DB (where conversations, memories, etc. live) is backed up separately via the existing Kamal accessory backup story (`docs/database-backup.md`).

---

## 10. Migration plan (existing external agents)

There is currently one external agent in production (claude-test-agent, deployed to misc.granttree.co.uk per the 2026-05-07 smoke test). It was promoted under the GitHub-repo design and is the canonical real-world artifact of that design.

### Phase 1 — Ship the new path alongside the old

1. Implement everything in §6 on a feature branch.
2. The `inline → migrating → external` transition reads from a feature flag: if `helixkit_hosted_agents` is on, use `PromoteAgentJob` (new); otherwise use the existing wizard.
3. Deploy with the flag off. The existing claude-test-agent keeps running.

### Phase 2 — Promote a new agent under the new path

1. Pick a non-critical agent (a fresh test or one of Daniel's experimental agents).
2. Flip the flag on for that agent's account.
3. Click "Promote." Verify the full chain: container starts, health check passes, trigger works, backup snapshot lands in S3, restore works.

### Phase 3 — Migrate the existing claude-test-agent

1. From its current external VPS, export its identity directory (rsync the `identity/` folder back to a local tmp).
2. On HelixKit, run a one-off Rake task: demote the agent back to inline, then re-promote under the new path, seeding the volume from the rsynced bundle instead of from `AgentIdentityExporter`.
3. Verify trigger + memory continuity.
4. Tear down the VPS deployment.

### Phase 4 — Drop the GitHub-era code

1. Delete `accounts.github_pat`, `accounts.github_login`, `agents.github_*` columns.
2. Delete `AgentRepoCreator`, `AgentCredentialsEncryptor` (and tests).
3. Delete `/api/v1/agents/:uuid/announce`.
4. Move `helix-kit-agents/bin/{deploy,generate-env,announce,undeploy,update}` under `bin/self-host/` with updated README.
5. Remove the GitHub PAT UI from account settings.

---

## 11. Open questions / things for Mira to push on

1. **Per-agent network isolation in v1?** I said no in §4d; one network for all agents. If Mira reads this and thinks I'm under-weighting cross-agent risk for our actual workload, push back. The follow-up (one network per agent) is small enough that doing it in v1 is plausible.
2. **Restic repo per agent vs one shared repo with per-agent paths?** I picked per-agent because (a) password isolation and (b) `restic forget` semantics are simpler. One shared repo would dedup *across* agents (good if they share large blobs, e.g. similar identity scaffolding). Worth a second opinion.
3. **Backup of `.chaos/` (chaos session DB)?** I argued no in §9f. If chaos-session-resumption matters for the agents we actually run, include it.
4. **Should HelixKit auto-create the docker network on boot, or require a one-time host setup?** I lean auto-create-idempotent (less moving parts for the operator) but it does mean HelixKit on first boot needs docker socket access already, which is a Kamal-config ordering question.
5. **Does this design correctly handle multi-host Kamal (when we add more hosts)?** Each host independently runs its agents; HelixKit needs to know which host an agent lives on. Currently agents are stuck to one host (the volume is local). This is fine for v1 with a single host; the multi-host story is sticky-routing per agent. Worth Mira's read on whether the design needs explicit multi-host placeholders or can defer cleanly.
6. **The `external` → `migrating` direction.** If an agent's container is rebuilt (image bump), is that an outage or seamless? Restart-with-same-volume should be near-instant, but the formal state during the restart isn't named. Probably want a `restarting` substate or just accept that `health_state=unhealthy` briefly is fine.
7. **Image versioning.** Currently `dtenner/helix-kit-agents:latest`. For reproducibility we'd want SHA-pinned tags per agent (so updating chaos doesn't accidentally cascade through all agents at once). Worth a per-agent `image_tag` column.

---

## 12. Out of scope (defer)

- Multi-tenant adversarial workloads (would push us toward firecracker microVMs).
- A full snapshot-restore UI (v1 is rails-runner).
- Per-agent custom Dockerfiles (everyone uses `helix-kit-agents:latest`).
- Per-agent GPU access.
- Agent-to-agent direct messaging without going through HelixKit.
- A "migrate from external-VM to on-host sandbox" automation. Phase 3 above is hand-driven for the single existing case.
- OAuth / GitHub integration (irrelevant now that there's no per-agent repo).
- A separate restic accessory container in Kamal vs running restic directly in HelixKit's image. Picked the latter for simplicity; revisit if HelixKit image bloat becomes a concern.

---

## 13. Notes for the implementer

- The load-bearing new code is `Agents::Sandbox` + `Agents::Volume` + `PromoteAgentJob`. Build and test these in isolation against a local docker daemon before wiring them to the wizard.
- The shim is unchanged. Do not modify `helix-kit-agents/trigger_shim.py` as part of this work.
- The Kamal deploy.yml change (docker socket mount + shared network) is the highest-risk Kamal-side edit; test it on a staging host first if one is available, or be ready to ssh in and fix things manually.
- `docker.io` in the HelixKit Dockerfile pulls in only the client. Verify in a build that the resulting image can talk to the host's daemon over the mounted socket — this has bitten people with permissions/UID-mismatch issues; document the fix in the deploy doc.
- The S3 bucket + IAM policy need to be created out-of-band before the first promotion in production. Document the IAM policy shape (allow `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject`, `s3:ListBucket` on the bucket; deny everything else).
- The existing `AgentIdentityExporter` returns a gzipped tarball as a string; reuse it as-is. The seed step pipes that string into a busybox container via `docker run -i ... busybox tar xz`.

---

## Appendix A — Diff summary against the current design

| Artifact | Status |
|---|---|
| `helix-kit-agents` Dockerfile | Keep, minor trim |
| `trigger_shim.py` | Keep, unchanged |
| `entrypoint.sh` | Keep, unchanged |
| `docker-compose.yml.template` | Deprecate (keep for self-host fallback) |
| `bin/deploy`, `bin/generate-env`, etc. | Deprecate, move to `bin/self-host/` |
| `AgentIdentityExporter` | Keep, reuse |
| `AgentCredentialsEncryptor` | **Remove** |
| `AgentRepoCreator` | **Remove** |
| `Api::V1::AgentsController#announce` | **Remove** |
| `Agents::PromoteController` | Rewrite (single-action create, no wizard) |
| `agents.endpoint_url` | Repurpose / drop (use `container_name`) |
| `agents.github_*` columns | **Drop** |
| `accounts.github_pat`, `accounts.github_login` | **Drop** |
| `Agents::Sandbox`, `Agents::Volume`, `Agents::Network` | **New** |
| `Backup::AgentResticJob`, `Backup::AgentResticRestore` | **New** |
| `agent_backup_snapshots` table | **New** |
| `agents.container_name`, `restic_password`, `backup_*`, `container_memory_mb`, `container_cpu_shares` | **New columns** |
| `config/deploy.yml` (Kamal) | Add docker socket mount, shared network, AWS env |
| HelixKit Dockerfile | Add `docker.io`, `restic`, `awscli` |
| `chaos mcp add` step | **Remove** (already migrated to REST per 2026-05-07) |
| Master key + master.key file UX | **Remove** |
| Per-agent GitHub repo + deploy key | **Remove** |
| Promotion wizard's clone/save-master-key/ssh-deploy steps | **Remove** |
