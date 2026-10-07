# syntax=docker/dockerfile:1
# CI tooling only. No application source, credentials or production image.
ARG RUBY_VERSION=4.0.6
ARG BUN_VERSION=1.4.0
ARG NODE_VERSION=22.23.3
FROM oven/bun:${BUN_VERSION} AS bun
FROM node:${NODE_VERSION}-bookworm-slim AS node
FROM ruby:${RUBY_VERSION}-slim-bookworm

ARG PLAYWRIGHT_VERSION=1.55.0
ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright
COPY --from=bun /usr/local/bin/bun /usr/local/bin/bun
COPY --from=node /usr/local/bin/node /usr/local/bin/node
RUN apt-get update && apt-get install --no-install-recommends -y \
    build-essential ca-certificates curl git libpq-dev libvips libyaml-dev ffmpeg \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /opt/playwright
RUN bun add --exact playwright@${PLAYWRIGHT_VERSION} \
    && node node_modules/playwright/cli.js install --with-deps chromium \
    && rm -rf /var/lib/apt/lists/* /root/.bun/install/cache \
    && chmod -R a+rX /ms-playwright
WORKDIR /work
