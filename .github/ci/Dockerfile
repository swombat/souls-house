# syntax=docker/dockerfile:1
# CI tooling only. No application source, credentials or production image.
ARG RUBY_VERSION=4.0.9
ARG BUN_VERSION=1.4.4
ARG NODE_VERSION=22.23.3
FROM oven/bun:${BUN_VERSION}@sha256:1d22548f177f4ff38e0c15baa3c2c46c6c2060ba2d1bc573bb4720b407548f1d AS bun
FROM node:${NODE_VERSION}-trixie-slim@sha256:28d03803f09ba76560e273af33beb7eda4ed68fa0698bc9bd15e9a6e35693923 AS node
FROM ruby:${RUBY_VERSION}-slim-trixie@sha256:88f0d8f1f2f7829c8c85c5cfee774f7ac936a7ba460e904e8c873b6a7f96c311

ARG PLAYWRIGHT_VERSION=1.55.0
ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright
COPY --from=bun /usr/local/bin/bun /usr/local/bin/bun
COPY --from=node /usr/local/bin/node /usr/local/bin/node
RUN apt-get update && apt-get install --no-install-recommends -y \
    build-essential ca-certificates curl git pkg-config libffi-dev libpq-dev libvips libyaml-dev ffmpeg \
    python3 python3-yaml openssh-client util-linux \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /opt/playwright
RUN bun add --exact playwright@${PLAYWRIGHT_VERSION} \
    && node node_modules/playwright/cli.js install --with-deps chromium \
    && rm -rf /var/lib/apt/lists/* /root/.bun/install/cache \
    && chmod -R a+rX /ms-playwright
WORKDIR /work
