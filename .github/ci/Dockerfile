# syntax=docker/dockerfile:1
# CI tooling only. No application source, credentials or production image.
ARG RUBY_VERSION=4.0.6
ARG BUN_VERSION=1.4.0
ARG NODE_VERSION=22.23.3
FROM oven/bun:${BUN_VERSION}@sha256:5ff609364c049b54eb0ff560ec96319729a972078ef2c755d758f0c6ef89c2d6 AS bun
FROM node:${NODE_VERSION}-bookworm-slim@sha256:c3de60bf2f9dd0ac6370e6117950ff62d6e339527e7472301c9c78a017978392 AS node
FROM ruby:${RUBY_VERSION}-slim-bookworm@sha256:749a0f614abbe145f6f29c7d099ddcc010fcf92a531a3500b40a78ea85af75ce

ARG PLAYWRIGHT_VERSION=1.55.0
ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright
COPY --from=bun /usr/local/bin/bun /usr/local/bin/bun
COPY --from=node /usr/local/bin/node /usr/local/bin/node
RUN apt-get update && apt-get install --no-install-recommends -y \
    build-essential ca-certificates curl git pkg-config libffi-dev libpq-dev libvips libyaml-dev ffmpeg \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /opt/playwright
RUN bun add --exact playwright@${PLAYWRIGHT_VERSION} \
    && node node_modules/playwright/cli.js install --with-deps chromium \
    && rm -rf /var/lib/apt/lists/* /root/.bun/install/cache \
    && chmod -R a+rX /ms-playwright
WORKDIR /work
