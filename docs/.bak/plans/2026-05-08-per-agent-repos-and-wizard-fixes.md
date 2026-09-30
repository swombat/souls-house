# Per-agent git repos + wizard text fixes

## Context

The agent-promotion architecture (see `2026-05-04-agent-promotion-ux.md` and `2026-05-07-mcp-to-skillfile-migration.md`) has two structural gaps surfaced by Daniel during 2026-05-07's end-to-end testing:

### Gap 1 — Per-agent git repo missing

The wizard currently instructs users to `git clone https://github.com/swombat/helix-kit-agents.git` — Daniel's *template* repo. That gives the agent:
- A clone whose `origin` points at someone else's repo (Daniel's template)
- No commit access (the agent's deploy key would be for the template, which is wrong)
- No place to record its evolving identity over time

The original spec ("agents authoring their identity over time") implicitly required each agent to have its own git repo. That implementation step was missing.

### Gap 2 — Wizard text is stale and incomplete

The promote.svelte wizard:
- Says *"configures HelixKit MCP"* — false post-migration; bin/deploy no longer does that
- Doesn't mention `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` prereq (caused multiple deploy failures during 2026-05-07 testing)
- Doesn't mention macOS Python SSL setup (caused two announce failures)
- Doesn't mention `--local` mode for testing
- Step 4 says `--host your-docker-host` only

This document specs both fixes. Both should land in the same body of work because gap 1's wizard-flow change naturally subsumes gap 2's wizard-text rewrite.

---

## Design

### Per-agent repo lifecycle

Each agent gets its own GitHub repo, **owned by the user** (the HelixKit account owner who initiated the promotion). The user retains control; HelixKit doesn't host the repo.

**Pattern: GitHub template repository.**
- `swombat/helix-kit-agents` is marked as a **template repository** via GitHub's UI (Settings → Template repository).
- The wizard creates each agent's repo via `POST /repos/{template_owner}/{template_repo}/generate` — this creates a fresh, independent repo (not a fork) initialised from the template.
- The wizard then commits the agent's identity files (master.key NEVER, but soul.md, helixkit-api.md, self-narrative.md, bootstrap.md, memory/, plus deploy.yml prefilled) via the GitHub API's contents endpoint.
- The wizard generates an **SSH deploy key**, uploads the public half via `POST /repos/{owner}/{repo}/keys` (with `read_write: true`), and stores the private half encrypted in HelixKit's DB so it can be embedded in the deploy bundle.

**Auth model.** The user grants HelixKit a GitHub PAT scoped to:
- `repo` (full control of private repos — needed for template-generate + contents-write + key-upload)
- Optionally `delete_repo` if HelixKit's "cancel promotion" should also delete the per-agent repo (defer this decision; default to "no, leave the repo")

PAT is stored encrypted in HelixKit's DB on the user record (or account record — pick the simpler one) and used only at promotion time. After promotion, all interaction is via the deploy key, which lives in the agent's own repo.

### What the user sees

Wizard flow (new):

1. **Configure GitHub access** — first-time only. Paste a PAT with `repo` scope. Validated by hitting `/user` and showing the GitHub username + avatar back. Stored encrypted.
2. **Confirm per-agent repo** — defaults: owner = the user's GitHub login; name = `<agent-slug>-agent` (e.g. `claude-test-agent-agent`); private. User can override.
3. **Generate credentials** — same as today, plus:
   - Wizard creates the repo from template
   - Wizard pushes agent identity files (and a prefilled `deploy.yml`) as the second commit
   - Wizard generates an ed25519 deploy key, uploads public half, stores private half encrypted
4. **Clone instructions** — now points at the new per-agent repo:
   ```
   git clone git@github.com:<user>/<agent-slug>-agent.git
   cd <agent-slug>-agent
   ```
5. **Save master key + credentials** — user pastes master_key into `master.key` (still one-time display). credentials.yml.enc lands via the wizard's commit at step 3, so user doesn't need to paste it manually anymore — just `git pull` after the wizard finishes.
6. **Set environment + deploy** — replaces the current step 4. Includes prereqs.

### Container's git push capability

The container needs to be able to commit + push to the agent's repo. Two paths:

**Option A — deploy key mounted into container (preferred).**
- bin/deploy reads the encrypted deploy key from credentials.yml.enc (decrypted with master.key, alongside the other secrets)
- bin/generate-env writes the private key to a tmpfs path (e.g. `/run/agent-deploy-key`) that's bind-mounted into the container
- Container's chaos process uses `GIT_SSH_COMMAND="ssh -i /run/agent-deploy-key -o StrictHostKeyChecking=accept-new"` for any git ops
- Identity directory inside container is a real working tree — `git status`, `git commit`, `git push` all work
- chaos's bash tool has access to git via PATH

**Option B — HTTPS with token.**
Simpler but rotates worse. Skip in favor of A.

---

## Schema changes (helix_kit)

### Migration: add per-agent repo fields

```ruby
class AddRepoFieldsToAgents < ActiveRecord::Migration[8.1]
  def change
    add_column :agents, :github_repo_url,        :string  # e.g. "https://github.com/swombat/claude-test-agent-agent"
    add_column :agents, :github_repo_owner,      :string  # "swombat"
    add_column :agents, :github_repo_name,       :string  # "claude-test-agent-agent"
    add_column :agents, :github_deploy_key_id,   :string  # GitHub's numeric key id, for revocation
    add_column :agents, :github_deploy_key_priv, :text    # encrypted at rest

    # Per-account/user GitHub PAT
    add_column :accounts, :github_pat,           :text    # encrypted at rest
    add_column :accounts, :github_login,         :string  # for display; cached at PAT-setup time
  end
end
```

Both `github_deploy_key_priv` and `github_pat` should use Rails 7+ `encrypts` so they're encrypted at rest in the DB.

---

## Implementation order

### Phase A — GitHub auth + repo creation skeleton

1. **`AgentRepoCreator`** service in `app/lib/`:
   - `#create_repo!` — POST to `/repos/{template_owner}/{template_repo}/generate`, returns owner + name + clone_url
   - `#commit_identity_files!(agent, master_key, credentials_yml_enc)` — uses contents API to commit identity files + prefilled deploy.yml + credentials.yml.enc to the new repo
   - `#create_deploy_key!(agent)` — generates an ed25519 keypair via Ruby's OpenSSL, uploads public via `/repos/{owner}/{repo}/keys`, returns key_id + private key
2. **`Account#github_pat`** — encrypted attribute, with a setter that validates against `/user` before storing.
3. **Settings UI** — page where user pastes their PAT and sees their GitHub login back. (Or surface this as the first step of the wizard if no PAT exists yet — UX call.)

### Phase B — Wizard integration

4. **`Agents::PromoteController#begin`** updated:
   - Before generating credentials, check `Current.account.github_pat` exists. If not, redirect to settings with a return-to.
   - After generating master_key + encrypted credentials (existing logic), call `AgentRepoCreator` to:
     - Create the repo
     - Generate deploy key
     - Commit identity (rendered by `AgentIdentityExporter` — refactor it to expose individual file contents instead of just a tarball, or keep the tarball and the wizard extracts it server-side)
     - Commit credentials.yml.enc
     - Commit a prefilled deploy.yml with agent_id, agent_uuid, endpoint_url placeholder, etc.
   - Persist `github_repo_url`, `github_repo_owner`, `github_repo_name`, `github_deploy_key_id`, `github_deploy_key_priv` on the agent.
5. **`AgentCredentialsEncryptor`** updated to include `github_deploy_key_priv` in the encrypted YAML so it's available at deploy time. Plaintext YAML gains:
   ```yaml
   github:
     deploy_key: |
       -----BEGIN OPENSSH PRIVATE KEY-----
       ...
   ```
6. **`promote.svelte`** rewritten:
   - Step 1: Configure GitHub access (or skip if already configured)
   - Step 2: Confirm repo name + visibility
   - Step 3: Generate (button) — fires the begin endpoint, shows progress
   - Step 4: Save master_key (one-time display, paste into `master.key` after clone)
   - Step 5: Clone the new repo (the new clone_url)
   - Step 6: Set environment + deploy (see "Wizard text" below)
   - Step 7: Verification (existing send_test_request, unchanged)

### Phase C — helix-kit-agents updates

7. **GitHub UI** (manual, by Daniel): Settings → Template repository → Mark `swombat/helix-kit-agents` as a template.
8. **`bin/deploy`** changes:
   - When generate-env decrypts credentials and finds `github.deploy_key`, write it to `/run/agent-deploy-key-<agent_id>` mode 0600.
   - Pass that path into the container via `docker-compose.yml.template` as an env var or bind mount.
9. **`docker-compose.yml.template`**:
   - Add a bind-mount for `/run/agent-deploy-key-<agent_id>:/run/agent-deploy-key:ro`
   - Add env: `GIT_SSH_COMMAND=ssh -i /run/agent-deploy-key -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null`
10. **`Dockerfile`** — install `openssh-client` in the runtime stage so chaos can use SSH for git.
11. **`README.md`** — update Quick start to reflect new flow (no more direct clone of helix-kit-agents; users get a per-agent repo from the wizard).

### Phase D — Wizard text rewrite (consolidates gap 2)

12. Update **promote.svelte**'s deploy section to read approximately:

```markdown
## Set environment

Before deploying, set these in your shell:

- `ANTHROPIC_API_KEY` (or `OPENAI_API_KEY` if you're using OpenAI as your provider)
- On macOS, `SSL_CERT_FILE=$(python3 -m certifi)` if your Python doesn't have a CA bundle wired up
  (you'll know if `bin/deploy` fails the announce step with `CERTIFICATE_VERIFY_FAILED`)

## Deploy

For local testing on your laptop:
    bin/deploy --local

For a production host:
    bin/deploy --host your-docker-host

The deploy script: rsyncs the repo, decrypts credentials, builds the image, brings up the
container, polls /health, and announces back to HelixKit. Keep this page open until the
runtime changes to "external".
```

Drop the *"configures HelixKit MCP"* sentence entirely.

---

## Test plan

Mirror the structure of `docs/agent-setup-test.md`. Key checks:

1. **Phase 0** — User pastes a PAT in settings, sees their GitHub login back. Valid PAT accepted; invalid PAT rejected with a clear error.
2. **Phase 1** — Click promote. Verify:
   - A new repo `<user>/<agent-slug>-agent` exists on GitHub
   - It contains `identity/`, `deploy.yml`, `credentials.yml.enc`, `bin/deploy`, etc. (template + commits)
   - A deploy key is registered on the repo (visible in GitHub UI under Settings → Deploy keys)
   - DB has `github_repo_url`, `github_deploy_key_priv`, `github_deploy_key_id` populated
3. **Phase 2** — User clones the per-agent repo, sets master.key, sets `ANTHROPIC_API_KEY`, runs `bin/deploy --local`. Verify:
   - `.env` contains `ANTHROPIC_API_KEY` (read from host shell)
   - Container starts, `/health` 200
   - Announce succeeds
   - Container has the deploy key mounted: `docker exec ... ls /run/agent-deploy-key`
4. **Phase 3** — Inside the container, as the agent user, verify `git status`, `git commit -m test`, `git push origin main` all work from the identity directory. Then revert the test commit so the agent's repo isn't polluted.
5. **Phase 4** — Cancel promotion. Verify the GitHub repo is **not** auto-deleted (per the design decision). Agent.runtime back to inline. Deploy key still on the repo (let the user revoke if they want; HelixKit doesn't auto-revoke either, defer that).

---

## Out of scope (defer)

- **OAuth flow instead of PAT.** PAT is simpler for v1. OAuth is a follow-up.
- **GitHub org accounts as repo owner.** v1 = user's personal account only. Org support is a follow-up.
- **Auto-revoke deploy key on cancel-promotion.** Cleaner but more code. Manual revocation is fine for v1.
- **Auto-merge upstream template updates.** When `helix-kit-agents` template gets updates (new chaos version, new tools), per-agent repos will go stale. A follow-up adds a "pull latest from template" button or auto-PR. Skip for v1.
- **Multi-provider auth.** GitLab, Bitbucket, Codeberg. v1 = GitHub only.
- **Hosting Daniel's existing test agent (claude-test-agent-agent).** It was created under the old flow. Either: re-promote from scratch (recommended, clean slate), or write a one-off migration script (not worth it for one agent).

---

## Notes for codex

- The `AgentRepoCreator` service is the load-bearing new code. Build + test it in isolation first (write integration tests that actually hit GitHub's API with a test repo, then move to mocked tests for CI).
- The wizard is the second-most-load-bearing piece — get the auth-and-repo-create flow working before fixing the cosmetic text.
- The helix-kit-agents repo changes (Dockerfile, bin/deploy, docker-compose.yml.template) need to be committed and pushed BEFORE the wizard creates new repos from the template — otherwise new agent repos won't have the SSH-key-aware deploy script.
- Daniel will mark the helix-kit-agents repo as a template via GitHub's UI separately (one-time manual step, not codex's job).
- After this lands, the existing claude-test-agent should be cancelled and re-promoted under the new flow. Its current repo at `~/dev/helix-test-agents/claude-test-agent-agent` was made under the old (clone-the-template) pattern and is structurally wrong.

The earlier specs `2026-05-04-agent-promotion-ux.md`, `2026-05-07-mcp-api-parity.md` (SUPERSEDED), and `2026-05-07-mcp-to-skillfile-migration.md` are reference reading. The migration spec is implemented; the API-parity spec is dead; this spec extends the migration spec.
