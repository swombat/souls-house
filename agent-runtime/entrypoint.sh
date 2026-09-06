#!/bin/sh
# entrypoint.sh — runs as root inside the container; fixes permissions on
# docker-managed volumes, then drops to the `agent` user (uid 1000) before
# exec'ing the shim.

set -e

AGENT_HOME=/home/agent
AGENT_REPO_PATH="${AGENT_REPO_PATH:-$AGENT_HOME/repo}"

# External-service credentials are runtime-supplied hosting context. The source
# is copied into the container before first boot; copy it into tmpfs for the
# resident and never into identity, repository, work, state, or Chaos volumes.
if [ -f /run/helixkit-source.yml ]; then
    mkdir -p /run/helixkit
    cp /run/helixkit-source.yml /run/helixkit/services.yml
    chown 1000:1000 /run/helixkit
    chmod 0700 /run/helixkit
    chown 1000:1000 /run/helixkit/services.yml
    chmod 0600 /run/helixkit/services.yml
fi

# Docker-managed volumes are root-owned when first created. The agent user needs
# write access to both canonical identity/memory and chaos session state.
for path in "$AGENT_HOME/identity" "$AGENT_HOME/.chaos" "$AGENT_REPO_PATH" "$AGENT_HOME/work" "$AGENT_HOME/state"; do
    if [ -d "$path" ]; then
        chown -R 1000:1000 "$path" || true
    fi
done

# Install hosted BeforeTurn recall and Stop journal/handle-formation reflexes.
# Stop blocks once after a turn, inviting authored memory or "no shape".
# The hook scripts live in identity so they
# is visible in the hosting filesystem browser. hooks.json is installed into the
# active repo's .chaos directory, where Chaos discovers project hooks.
mkdir -p "$AGENT_HOME/identity/automation" \
         "$AGENT_HOME/identity/memory/daily-journals" \
         "$AGENT_HOME/identity/memory/automation/state" \
         "$AGENT_HOME/.chaos" \
         "$AGENT_REPO_PATH/.chaos" \
         "$AGENT_HOME/work" \
         "$AGENT_HOME/state/claude" \
         "$AGENT_HOME/state/antigravity"
chmod 0700 "$AGENT_HOME/state" "$AGENT_HOME/state/claude" "$AGENT_HOME/state/antigravity"

# Chaos bundles Anthropic, OpenAI, and xAI providers. Hosted agents also need
# the two providers RubyLLM may select that are not bundled by Chaos itself.
# Append only missing sections so persisted/user-managed settings win.
CHAOS_CONFIG="$AGENT_HOME/.chaos/config.toml"
touch "$CHAOS_CONFIG"
if ! grep -q '^\[model_providers\.gemini\]' "$CHAOS_CONFIG"; then
    cat >> "$CHAOS_CONFIG" <<'GEMINI_PROVIDER'

[model_providers.gemini]
name = "Gemini"
base_url = "https://generativelanguage.googleapis.com/v1beta/openai"
env_key = "GEMINI_API_KEY"
wire_api = "chat_completions"
GEMINI_PROVIDER
fi
if ! grep -q '^\[model_providers\.openrouter\]' "$CHAOS_CONFIG"; then
    cat >> "$CHAOS_CONFIG" <<'OPENROUTER_PROVIDER'

[model_providers.openrouter]
name = "OpenRouter"
base_url = "https://openrouter.ai/api/v1"
env_key = "OPENROUTER_API_KEY"
wire_api = "chat_completions"
OPENROUTER_PROVIDER
fi
chown 1000:1000 "$CHAOS_CONFIG" || true

# Refresh pristine hooks, but preserve resident edits and stage new stock for review.
python3 /usr/local/share/helixkit-agent/install_memory_scripts.py \
    /usr/local/share/helixkit-agent "$AGENT_HOME/identity/automation"
install_hooks_json() {
    target="$1"
    python3 /usr/local/share/helixkit-agent/install_memory_hooks.py "$target"
}
# Chaos reads hooks from both global and project config. Install managed hooks
# only into the active project (`-C`) so it fires once per turn. If an earlier
# HelixKit image wrote the same managed hook into ~/.chaos/hooks.json, remove it.
install_hooks_json "$AGENT_REPO_PATH/.chaos/hooks.json"
if [ -f "$AGENT_HOME/.chaos/hooks.json" ] && grep -q "hosted-agent-stop-journal-reflex:" "$AGENT_HOME/.chaos/hooks.json"; then
    python3 /usr/local/share/helixkit-agent/install_memory_hooks.py "$AGENT_HOME/.chaos/hooks.json" --remove
fi
cat > "$AGENT_HOME/.chaos/helixkit-hooks.md" <<'HOOKS_NOTE'
# HelixKit hosted-agent hooks

The managed BeforeTurn recall and Stop memory-formation hooks are installed at:

`/home/agent/repo/.chaos/hooks.json`

Chaos may read both global (`~/.chaos`) and project (`-C .../.chaos`) hooks, so
HelixKit does not install a second copy here. Keeping only one active hook avoids
duplicate reflexes. Your other hooks are preserved. `house-memory guide`
explains the memory practice; no-shape remains a valid Stop response.

Resident-modified hook scripts stay active across boots. Pending stock updates
are listed in `identity/automation/HOUSE-HOOK-UPDATES.md`, with `.upstream`
copies alongside the active scripts and last-installed stock in `.house-stock/`.
Review both sides before rebasing; preserving your edits does not automatically
incorporate new house features.
HOOKS_NOTE
if [ ! -f "$AGENT_HOME/identity/memory/daily-journals/README.md" ]; then
    cat > "$AGENT_HOME/identity/memory/daily-journals/README.md" <<'README'
# Daily journals

This folder holds diarized memory for the hosted agent. After each Chaos turn, a
Stop hook invites the agent to either write a short first-person journal entry
for the current day, or answer `no shape` when nothing should be kept.

Daily files are named `YYYY-MM-DD.md`. Each entry uses:

```markdown
## HH:MM — <title naming the shape, not the topic>
```

These journals are source material for future daily, weekly, and monthly memory
summaries. Do not treat them as task logs; write only what is worth preserving
for continuity.

When adding an entry to an existing daily file, append a new section. Do not
overwrite or truncate existing entries; with shell redirection, use >> rather
than > for an existing journal.
README
fi
chown -R 1000:1000 "$AGENT_REPO_PATH" "$AGENT_HOME/work" "$AGENT_HOME/state" "$AGENT_HOME/identity/automation" "$AGENT_HOME/identity/memory" "$AGENT_HOME/.chaos/helixkit-hooks.md" 2>/dev/null || true

# Some chaos providers read API keys directly from the environment (Anthropic),
# while others require a provider account entry under the agent user's ~/.chaos.
# Seed those account entries opportunistically from host-supplied env vars on
# every boot. This writes into the persisted chaos-home volume and is idempotent;
# never echo the key.
register_provider_key() {
    provider="$1"
    key="$2"
    if [ -n "$key" ]; then
        printf '%s' "$key" | gosu agent chaos accounts --provider "$provider" --with-api-key >/dev/null 2>&1 || true
    fi
}

register_provider_key anthropic "$ANTHROPIC_API_KEY"
register_provider_key openai "$OPENAI_API_KEY"

# Keep one matching Chaos journal daemon alive for the lifetime of the hosted
# runtime. Long-running provider turns and later resume processes must share the
# same socket instead of relying on per-command detached bootstrap. Keep the
# post-storage-refactor journal separate from legacy chaos.sqlite databases:
# SQLx correctly refuses to reuse a database whose original migration changed.
export CHAOS_HOME="${CHAOS_HOME:-$AGENT_HOME/.chaos}"
export CHAOS_JOURNALD_SOCKET="${CHAOS_JOURNALD_SOCKET:-$CHAOS_HOME/run/journald.sock}"
CHAOS_JOURNALD_DB="${CHAOS_JOURNALD_DB:-$CHAOS_HOME/journal.sqlite}"
mkdir -p "$(dirname "$CHAOS_JOURNALD_SOCKET")"
chown -R 1000:1000 "$CHAOS_HOME"
gosu agent chaos_journald \
    --socket "$CHAOS_JOURNALD_SOCKET" \
    --db "$CHAOS_JOURNALD_DB" &
CHAOS_JOURNALD_PID=$!

attempt=0
while [ ! -S "$CHAOS_JOURNALD_SOCKET" ]; do
    if ! kill -0 "$CHAOS_JOURNALD_PID" 2>/dev/null; then
        echo "chaos_journald stopped before creating its socket" >&2
        exit 1
    fi
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 100 ]; then
        echo "timed out waiting for chaos_journald socket" >&2
        exit 1
    fi
    sleep 0.05
done

# Optional local guardrail if the identity volume is itself a git working tree.
# The hosted path does not require git, but agents may initialize it for local
# history. Protect soul.md from accidental commits unless explicitly allowed.
if [ -d "$AGENT_HOME/identity/.git/hooks" ]; then
    cat > "$AGENT_HOME/identity/.git/hooks/pre-commit" <<'HOOK'
#!/bin/sh
set -e

if [ "${ALLOW_PROTECTED_IDENTITY_CHANGE:-}" = "1" ]; then
    exit 0
fi

protected='soul.md'
if git diff --cached --name-only -- "$protected" | grep -qx "$protected"; then
    cat >&2 <<'MSG'
Refusing to commit soul.md.

That file is the agent's defining system prompt and is protected. If Daniel has
explicitly reviewed and approved this change, rerun the commit with:

  ALLOW_PROTECTED_IDENTITY_CHANGE=1 git commit ...
MSG
    exit 1
fi
HOOK
    chmod 0755 "$AGENT_HOME/identity/.git/hooks/pre-commit" || true
    chown 1000:1000 "$AGENT_HOME/identity/.git/hooks/pre-commit" || true
fi

exec gosu agent "$@"
