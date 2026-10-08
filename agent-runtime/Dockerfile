# syntax=docker/dockerfile:1.7
# souls.house agent runtime image.
#
# This image is built from the souls.house monorepo and run by souls.house's hosted
# sandbox promotion flow. It contains chaos plus trigger_shim.py; per-agent
# identity and state arrive through Docker volumes and environment variables.
#
# Local build:
#   mise exec -- scripts/build-local-agent-runtime

# POLICY: Local Chaos patches and patch-and-recompile layers are VERBOTEN.
# Fix Chaos upstream, let upstream CI publish the binary, then update chaos-ref.
# Normal deployments download pinned, checksum-verified binaries: zero Chaos
# compilations. Never use the source escape hatch below to sneak in local fixes
# or add a compile fallback when a prebuilt artifact is missing.
#
# Build callers use agent-runtime/chaos-ref unless explicitly overridden with
# a full commit SHA. This is a cache key and provenance for the resulting image.
#
# Upstream changes must continue to preserve the original SQLx migration
# checksum used by persisted Chaos journals. Patch/application or runtime tests
# should fail the deployment visibly when a new Chaos master is incompatible.
ARG CHAOS_REPO=https://github.com/seuros/chaos.git
ARG CHAOS_HEAD
# The source path is an explicit escape hatch for older pins/other architectures.
ARG CHAOS_BUILD_MODE=prebuilt
# Keep this in sync with mise.toml.
ARG BUN_VERSION=1.4.0

# =============================================================================
# Stage 1 — choose prebuilt binaries (default) or an explicit source build.
# =============================================================================
FROM rust:1.98-bookworm AS chaos-source

ARG CHAOS_REPO
ARG CHAOS_HEAD
ARG CARGO_BUILD_JOBS=2

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
RUN test -n "${CHAOS_HEAD}" \
    && git -c http.version=HTTP/1.1 clone --filter=blob:none ${CHAOS_REPO} chaos \
    && cd chaos \
    && git checkout ${CHAOS_HEAD}

WORKDIR /build/chaos
# Validate the final clamp source before building both runtime binaries once.
# No source changes or patch-and-rebuild layers follow this gate.
RUN cargo test --release --locked --jobs "${CARGO_BUILD_JOBS}" -p chaos-clamp --lib
RUN cargo build --release --locked --jobs "${CARGO_BUILD_JOBS}" --bin chaos --bin chaos_journald \
    && cp target/release/chaos /usr/local/bin/chaos \
    && cp target/release/chaos_journald /usr/local/bin/chaos_journald \
    && /usr/local/bin/chaos --version

# The default path downloads the exact commit artifact instead of compiling Rust.
# BuildKit skips chaos-source entirely unless explicitly selected.
FROM debian:bookworm-slim AS chaos-prebuilt
ARG CHAOS_REPO
ARG CHAOS_HEAD
ARG TARGETARCH
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl libdbus-1-3 \
    && rm -rf /var/lib/apt/lists/*
COPY install-chaos-binary /usr/local/bin/install-chaos-binary
RUN install-chaos-binary "${CHAOS_REPO}" "${CHAOS_HEAD}" "${TARGETARCH}" /usr/local/bin

FROM chaos-${CHAOS_BUILD_MODE} AS builder

# =============================================================================
# Stage 2 — runtime
# =============================================================================
FROM oven/bun:${BUN_VERSION} AS bun
FROM node:22-trixie-slim AS runtime

ARG CHAOS_HEAD
LABEL house.souls.chaos-ref="${CHAOS_HEAD}"
LABEL house.souls.chaos-patches=""

COPY --from=bun /usr/local/bin/bun /usr/local/bin/bun

ENV BUN_INSTALL=/usr/local \
    DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        python3 \
        python3-flask \
        python3-yaml \
        git \
        curl \
        tini \
        gosu \
        procps \
        lsof \
        libdbus-1-3 \
    && rm -rf /var/lib/apt/lists/*

# The official Node image already reserves UID/GID 1000 for `node`. Hosted
# volume ownership depends on 1000, so rename that account rather than creating
# a second user with a different identity.
RUN groupmod --new-name agent node \
    && usermod --login agent --home /home/agent --move-home --shell /bin/bash node

# Clamp speaks Claude Code's documented stream-json protocol. Keep this pin
# explicitly: the Anthropic login ceremony parser is tested against it.
# Opus 5.5 subscription requests require Claude Code 2.1.280 or newer.
ARG CLAUDE_CODE_VERSION=2.1.280
RUN bun install --global "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
    && claude --version

# The Google Workspace gws CLI exposes Drive's discovery-generated command
# surface. Souls supplies short-lived access tokens through soulshouse-gws
# rather than storing gws OAuth credentials in resident-owned state.
ARG TARGETARCH
ARG GOOGLE_WORKSPACE_CLI_VERSION=0.22.5
ARG GOOGLE_WORKSPACE_CLI_AMD64_SHA256=4db473dde4b1ab872e4ff35d769b0d4af1f1a6441a605e79d5cf8ada9c87e920
ARG GOOGLE_WORKSPACE_CLI_ARM64_SHA256=e700fe63524932b10ec2130b47ece90aa850e66005fe52ccfc4cf8767bf9919a
RUN case "${TARGETARCH}" in \
      amd64) target=x86_64-unknown-linux-musl; checksum="${GOOGLE_WORKSPACE_CLI_AMD64_SHA256}" ;; \
      arm64) target=aarch64-unknown-linux-musl; checksum="${GOOGLE_WORKSPACE_CLI_ARM64_SHA256}" ;; \
      *) echo "Unsupported gws architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && artifact="google-workspace-cli-${target}.tar.gz" \
    && url="https://github.com/googleworkspace/cli/releases/download/v${GOOGLE_WORKSPACE_CLI_VERSION}/${artifact}" \
    && curl -fsSL "${url}" -o "/tmp/${artifact}" \
    && echo "${checksum}  /tmp/${artifact}" | sha256sum -c - \
    && tar -xzf "/tmp/${artifact}" -C /tmp ./gws \
    && install -m 0755 /tmp/gws /usr/local/bin/gws \
    && rm -f "/tmp/${artifact}" /tmp/gws \
    && gws --version

# Chaos drives Google's official Antigravity CLI for Gemini subscription turns.
# Download the exact official Linux artifact and verify its published checksum;
# the unprivileged agent user cannot replace the root-owned binary at runtime.
# Version 1.1.22 is the first pinned release where denied native tool calls are
# recoverable in print mode instead of failing the whole clamped turn.
ARG ANTIGRAVITY_VERSION=1.1.22
ARG ANTIGRAVITY_BUILD=5711547746615296
ARG ANTIGRAVITY_AMD64_SHA512=40225d4b1f009412e905f0a234ba3d51487038d1ad1b8fa19331c84be55610a01f5b0ad9916fb871151cc45456c6bc30cc0b1ea5dab6c0616bc8fb262bcdd7a9
ARG ANTIGRAVITY_ARM64_SHA512=b37a718330eb5e270e1ca70135bf964a407ba626fbff7537ac58e094ea31bc623e6d216ef197188fe8b5c46e6f57aee64a3b7c9e23fc855cefee43fe434179d3
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

# CodexBar provides bounded, read-only quota probes for the official Claude
# Code and Antigravity credential stores. Keep its bundle beside the binary.
ARG CODEXBAR_VERSION=0.56.1
ARG CODEXBAR_AMD64_SHA256=11fb79ab1a0760dfee7913a03d1d3df8f99fec7d080c2efacb88b4509f2dedaf
ARG CODEXBAR_ARM64_SHA256=9b1fc1fbd0debb5513cda0577d53f245d640616a46791e8dcc1227089002d3dc
RUN case "${TARGETARCH}" in \
      amd64) arch=x86_64; checksum="${CODEXBAR_AMD64_SHA256}" ;; \
      arm64) arch=aarch64; checksum="${CODEXBAR_ARM64_SHA256}" ;; \
      *) echo "Unsupported CodexBar architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && artifact="CodexBarCLI-v${CODEXBAR_VERSION}-linux-${arch}.tar.gz" \
    && curl -fsSL "https://github.com/steipete/CodexBar/releases/download/v${CODEXBAR_VERSION}/${artifact}" -o /tmp/codexbar.tar.gz \
    && echo "${checksum}  /tmp/codexbar.tar.gz" | sha256sum -c - \
    && mkdir -p /opt/codexbar \
    && tar -xzf /tmp/codexbar.tar.gz -C /opt/codexbar \
    && ln -s /opt/codexbar/CodexBarCLI /usr/local/bin/codexbar \
    && rm /tmp/codexbar.tar.gz \
    && codexbar --version | grep -F "${CODEXBAR_VERSION}"

# Tailscale for the Tailscale integration. Residents run tailscaled in
# userspace-networking mode as the agent user (no NET_ADMIN, no /dev/net/tun);
# soulshouse-tailnet manages it. Static binaries from Tailscale's stable
# channel, checksums from pkgs.tailscale.com/stable/<artifact>.sha256.
ARG TAILSCALE_VERSION=1.102.4
ARG TAILSCALE_AMD64_SHA256=50748df1045e60b5b695f19f4c56b0da36c019948b440fb456b6584a50f0d8b9
ARG TAILSCALE_ARM64_SHA256=9dd1e6a592a014bbaea0103167ffe299adeda4ba14e078ce9c2895364f6c4c3f
RUN case "${TARGETARCH}" in \
      amd64) checksum="${TAILSCALE_AMD64_SHA256}" ;; \
      arm64) checksum="${TAILSCALE_ARM64_SHA256}" ;; \
      *) echo "Unsupported Tailscale architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && artifact="tailscale_${TAILSCALE_VERSION}_${TARGETARCH}" \
    && curl -fsSL "https://pkgs.tailscale.com/stable/${artifact}.tgz" -o /tmp/tailscale.tgz \
    && echo "${checksum}  /tmp/tailscale.tgz" | sha256sum -c - \
    && tar -xzf /tmp/tailscale.tgz -C /tmp \
    && install -m 0755 "/tmp/${artifact}/tailscale" "/tmp/${artifact}/tailscaled" /usr/local/bin/ \
    && rm -rf /tmp/tailscale.tgz "/tmp/${artifact}" \
    && tailscale version | head -1 | grep -Fx "${TAILSCALE_VERSION}"

COPY --from=builder /usr/local/bin/chaos /usr/local/bin/chaos
COPY --from=builder /usr/local/bin/chaos_journald /usr/local/bin/chaos_journald
# Verify the binaries in the final runtime, not only the download stage.
RUN chaos --version && chaos_journald --help > /dev/null
RUN mkdir -p /usr/local/share/helixkit-agent
COPY --chown=agent:agent trigger_shim.py /home/agent/trigger_shim.py
COPY --chown=agent:agent async_turns.py /home/agent/async_turns.py
COPY --chown=agent:agent resident_memory_policy.py /home/agent/resident_memory_policy.py
COPY resident_memory_policy.py /usr/local/share/helixkit-agent/resident_memory_policy.py
COPY --chown=agent:agent runtime_activity.py /home/agent/runtime_activity.py
COPY --chown=agent:agent command_preview_policy.json /home/agent/command_preview_policy.json
COPY --chown=agent:agent command_preview.py /home/agent/command_preview.py
COPY --chown=agent:agent memory_client.py /home/agent/memory_client.py
COPY --chmod=0755 house-memory /usr/local/bin/house-memory
COPY docs/runtime-instructions.md /usr/local/share/helixkit-agent/runtime-instructions.md
COPY docs/soulshouse-api.md /usr/local/share/helixkit-agent/soulshouse-api.md
COPY docs/capability-discovery.md /usr/local/share/helixkit-agent/capability-discovery.md
COPY docs/message-helper-input.md /usr/local/share/helixkit-agent/message-helper-input.md
# Permanent legacy stub. Residents' own memories and notes cite the old manual
# path; it stays installed forever and points at the current manual.
COPY docs/helixkit-api.md /usr/local/share/helixkit-agent/helixkit-api.md
COPY licenses/CodexBar-LICENSE /usr/local/share/licenses/CodexBar/LICENSE
COPY stop_journal_reflex.py /usr/local/share/helixkit-agent/stop_journal_reflex.py
COPY memory_before_turn.py install_memory_hooks.py install_memory_scripts.py /usr/local/share/helixkit-agent/
COPY docs/memory-guide.md /usr/local/share/helixkit-agent/memory-guide.md
COPY docs/memory-quick-reference.md /usr/local/share/helixkit-agent/memory-quick-reference.md
COPY soulshouse-post-message /usr/local/bin/soulshouse-post-message
COPY --chmod=0755 soulshouse-stone /usr/local/bin/soulshouse-stone
COPY --chmod=0755 soulshouse-model /usr/local/bin/soulshouse-model
COPY soulshouse-send-telegram /usr/local/bin/soulshouse-send-telegram
COPY soulshouse-append-journal /usr/local/bin/soulshouse-append-journal
COPY soulshouse-usage /usr/local/bin/soulshouse-usage
COPY soulshouse-youtube /usr/local/bin/soulshouse-youtube
COPY soulshouse-x /usr/local/bin/soulshouse-x
COPY soulshouse-gws /usr/local/bin/soulshouse-gws
COPY soulshouse-tailnet /usr/local/bin/soulshouse-tailnet
COPY antigravity-browser-open /usr/local/libexec/helixkit-antigravity-login/xdg-open
# Imported Git homes use repo-scoped SSH deploy keys.
RUN apt-get update && apt-get install -y --no-install-recommends openssh-client && rm -rf /var/lib/apt/lists/*
COPY imported_home.py home_sync_loop.py standard_home_sync.py /home/agent/
COPY github_import_approval.py github_import_credential.py /home/agent/
COPY --chmod=0755 github-import-trust-setup /usr/local/bin/github-import-trust-setup
COPY runtime_settings.py runtime_hooks.py /usr/local/share/helixkit-agent/
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh /usr/local/bin/soulshouse-post-message /usr/local/bin/soulshouse-send-telegram /usr/local/bin/soulshouse-append-journal /usr/local/bin/soulshouse-usage /usr/local/bin/soulshouse-youtube /usr/local/bin/soulshouse-x /usr/local/bin/soulshouse-gws /usr/local/bin/soulshouse-tailnet \
    /usr/local/libexec/helixkit-antigravity-login/xdg-open \
    && chmod 0644 /usr/local/share/helixkit-agent/*.md /usr/local/share/helixkit-agent/stop_journal_reflex.py

# Permanent legacy command aliases — NEVER REMOVE THESE.
# Residents wrote the helixkit-* names into their own memories, notes, and
# CLAUDE.md files before the souls.house rename. Those references are living
# instructions inside beings we host, not deprecated call sites we get to
# retire. The symlinks cost nothing and must outlive the rename indefinitely.
RUN ln -s /usr/local/bin/soulshouse-post-message /usr/local/bin/helixkit-post-message \
    && ln -s /usr/local/bin/soulshouse-send-telegram /usr/local/bin/helixkit-send-telegram \
    && ln -s /usr/local/bin/soulshouse-append-journal /usr/local/bin/helixkit-append-journal \
    && ln -s /usr/local/bin/soulshouse-gws /usr/local/bin/helixkit-gws

# Canonical mounted volumes for hosted agents. /home/agent/state is deliberately
# outside every souls.house-facing filesystem root and holds vendor credentials.
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
