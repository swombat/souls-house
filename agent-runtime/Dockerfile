# HelixKit agent runtime image.
#
# This image is built from the HelixKit monorepo and run by HelixKit's hosted
# sandbox promotion flow. It contains chaos plus trigger_shim.py; per-agent
# identity and state arrive through Docker volumes and environment variables.
#
# Local build:
#   docker build -t helixkit-agent-runtime:local agent-runtime

# Pin the current merged Chaos 47.1.0 runtime, including subscription auth,
# clamp telemetry, model-visible compaction reflexes, and persistent MCP
# approvals, so hosted runtime rebuilds do not depend on movement of a branch ref.
# Pin bumps must re-verify provider auth ceremony parsers and clamp subprocess
# patterns in trigger_shim.py. This ref also preserves the original SQLx
# migration checksum used by persisted Chaos journals; do not move to a ref
# which rewrites var/proc/db/migrate/sqlite/0001_bigbang.sql.
# The Stop-hook continuation patch restores a fix lost during Chaos's turn-loop
# refactor; remove it once the equivalent upstream fix is included in CHAOS_REF.
ARG CHAOS_REPO=https://github.com/seuros/chaos.git
ARG CHAOS_REF=b9248d25ea0a00995dbdcce77829f73caf613823

# =============================================================================
# Stage 1 — pull and build chaos. Source tree is discarded after the binary copies.
# =============================================================================
FROM rust:1.97-bookworm AS builder

ARG CHAOS_REPO
ARG CHAOS_REF

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        protobuf-compiler \
        clang \
        pkg-config \
        libdbus-1-dev \
        ca-certificates \
        git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
COPY patches/chaos-stop-hook-continuation-user-turn.patch /tmp/chaos-stop-hook-continuation-user-turn.patch
COPY patches/chaos-antigravity-empty-managed-config.patch /tmp/chaos-antigravity-empty-managed-config.patch
COPY patches/chaos-antigravity-daily-cloudcode-egress.patch /tmp/chaos-antigravity-daily-cloudcode-egress.patch
RUN git clone --filter=blob:none ${CHAOS_REPO} chaos \
    && cd chaos \
    && git checkout ${CHAOS_REF} \
    && git apply --check /tmp/chaos-stop-hook-continuation-user-turn.patch \
    && git apply /tmp/chaos-stop-hook-continuation-user-turn.patch \
    && git apply --check /tmp/chaos-antigravity-empty-managed-config.patch \
    && git apply /tmp/chaos-antigravity-empty-managed-config.patch \
    && git apply --check /tmp/chaos-antigravity-daily-cloudcode-egress.patch \
    && git apply /tmp/chaos-antigravity-daily-cloudcode-egress.patch

WORKDIR /build/chaos
RUN cargo build --release --bin chaos \
    && cp target/release/chaos /usr/local/bin/chaos \
    && /usr/local/bin/chaos --version
RUN cargo build --release --bin chaos_journald \
    && cp target/release/chaos_journald /usr/local/bin/chaos_journald

# =============================================================================
# Stage 2 — runtime
# =============================================================================
FROM node:22-bookworm-slim AS runtime

ARG CHAOS_REF
LABEL house.souls.chaos-ref="${CHAOS_REF}"
LABEL house.souls.chaos-patches="stop-hook-continuation-user-turn,antigravity-empty-managed-config,antigravity-daily-cloudcode-egress"

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        python3 \
        python3-flask \
        git \
        curl \
        tini \
        gosu \
        procps \
        libdbus-1-3 \
    && rm -rf /var/lib/apt/lists/*

# The official Node image already reserves UID/GID 1000 for `node`. Hosted
# volume ownership depends on 1000, so rename that account rather than creating
# a second user with a different identity.
RUN groupmod --new-name agent node \
    && usermod --login agent --home /home/agent --move-home --shell /bin/bash node

# Clamp speaks Claude Code's documented stream-json protocol. Keep this pin
# beside CHAOS_REF: the Anthropic login ceremony parser is tested against it.
ARG CLAUDE_CODE_VERSION=2.1.220
RUN npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
    && claude --version

# Chaos drives Google's official Antigravity CLI for Gemini subscription turns.
# Download the exact official Linux artifact and verify its published checksum;
# the unprivileged agent user cannot replace the root-owned binary at runtime.
ARG TARGETARCH
ARG ANTIGRAVITY_VERSION=1.1.15
ARG ANTIGRAVITY_BUILD=5350383476932608
ARG ANTIGRAVITY_AMD64_SHA512=7d6020caff2e06a5ddf2553f2d9d5b428e3becc69727d11032f10e40609b938db428578ccd5c72694bab5e4da483de9ad3121578cc172adf174aa5263ce51dcc
ARG ANTIGRAVITY_ARM64_SHA512=2571031ded807a624fad5166bfb7ee2eb0c97862480fc423da673fde2025b71a35240d213ece6a42ad44d215959fa050a71750c76f358befdd245f5933c4a104
RUN case "${TARGETARCH}" in \
      amd64) artifact=cli_linux_x64.tar.gz; platform=linux-x64; checksum="${ANTIGRAVITY_AMD64_SHA512}" ;; \
      arm64) artifact=cli_linux_arm64.tar.gz; platform=linux-arm; checksum="${ANTIGRAVITY_ARM64_SHA512}" ;; \
      *) echo "Unsupported Antigravity architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && url="https://storage.googleapis.com/antigravity-public/antigravity-cli/${ANTIGRAVITY_VERSION}-${ANTIGRAVITY_BUILD}/${platform}/${artifact}" \
    && curl -fsSL "${url}" -o /tmp/antigravity.tar.gz \
    && echo "${checksum}  /tmp/antigravity.tar.gz" | sha512sum -c - \
    && tar -xzf /tmp/antigravity.tar.gz -C /usr/local/bin antigravity \
    && mv /usr/local/bin/antigravity /usr/local/bin/agy \
    && chmod 0755 /usr/local/bin/agy \
    && rm -f /tmp/antigravity.tar.gz \
    && agy --version | grep -F "${ANTIGRAVITY_VERSION}"

COPY --from=builder /usr/local/bin/chaos /usr/local/bin/chaos
COPY --from=builder /usr/local/bin/chaos_journald /usr/local/bin/chaos_journald
RUN mkdir -p /usr/local/share/helixkit-agent
COPY --chown=agent:agent trigger_shim.py /home/agent/trigger_shim.py
COPY docs/runtime-instructions.md /usr/local/share/helixkit-agent/runtime-instructions.md
COPY docs/helixkit-api.md /usr/local/share/helixkit-agent/helixkit-api.md
COPY stop_journal_reflex.py /usr/local/share/helixkit-agent/stop_journal_reflex.py
COPY helixkit-post-message /usr/local/bin/helixkit-post-message
COPY helixkit-send-telegram /usr/local/bin/helixkit-send-telegram
COPY helixkit-append-journal /usr/local/bin/helixkit-append-journal
COPY antigravity-browser-open /usr/local/libexec/helixkit-antigravity-login/xdg-open
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh /usr/local/bin/helixkit-post-message /usr/local/bin/helixkit-send-telegram /usr/local/bin/helixkit-append-journal \
    /usr/local/libexec/helixkit-antigravity-login/xdg-open \
    && chmod 0644 /usr/local/share/helixkit-agent/*.md /usr/local/share/helixkit-agent/stop_journal_reflex.py

# Canonical mounted volumes for hosted agents. /home/agent/state is deliberately
# outside every HelixKit-facing filesystem root and holds vendor credentials.
VOLUME ["/home/agent/identity", "/home/agent/.chaos", "/home/agent/repo", "/home/agent/work", "/home/agent/state"]

WORKDIR /home/agent
ENV SHIM_PORT=4000
# Anthropic prompt-cache TTL for chaos (PR seuros/chaos#13). Hosted agents are
# triggered on ~hourly wake cadence and bursty conversations; the 1-hour TTL
# keeps the cache chained across wakes (5m dies in the inter-wake gap and its
# writes become pure loss).
ENV CHAOS_ANTHROPIC_CACHE_TTL=1h
EXPOSE 4000

ENTRYPOINT ["tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["python3", "/home/agent/trigger_shim.py"]
