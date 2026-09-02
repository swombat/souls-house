# syntax=docker/dockerfile:1.7  # keep this at the very top of the Dockerfile

########################
# BASE (from ruby:4.0.6-slim)
########################

# Keep these runtime versions in sync with mise.toml and .ruby-version.
ARG RUBY_VERSION=4.0.6
ARG BUN_VERSION=1.4.0

FROM registry.docker.com/oven/bun:$BUN_VERSION AS bun
FROM registry.docker.com/library/ruby:$RUBY_VERSION-slim AS base

# Rails app lives here
WORKDIR /rails

# Set production environment
ARG RAILS_ENV=production
ENV BUNDLE_DEPLOYMENT="1" \
  BUNDLE_PATH="/usr/local/bundle" \
  BUNDLE_WITHOUT="development"

########################
# DEPENDENCIES (from base)
########################
# One consolidated apt layer (PGDG for psql 16, etc.)

# Dependencies base image to speed things up!
FROM base AS dependencies

# Use BuildKit cache to speed up apt metadata
# 1) Base apt tools (uses cache mount)
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    set -eux; \
    apt-get update -o Acquire::Retries=3; \
    apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg lsb-release xz-utils wget; \
    rm -rf /var/lib/apt/lists/*

# 2) PGDG repo (no apt cache needed here; just writing files)
RUN set -eux; \
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
      | gpg --dearmor > /usr/share/keyrings/pgdg.gpg; \
    echo "deb [signed-by=/usr/share/keyrings/pgdg.gpg] http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
      > /etc/apt/sources.list.d/pgdg.list

# 3) System deps (cache mount again)
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    set -eux; \
    apt-get update -o Acquire::Retries=3; \
    apt-get install -y --no-install-recommends \
      build-essential git openssh-client pkg-config \
      libvips libpq-dev libicu-dev libyaml-dev libssl-dev libreadline-dev zlib1g-dev \
      passwd vim neovim \
      postgresql-client-16 ffmpeg poppler-utils docker.io; \
    rm -rf /var/lib/apt/lists/*

########################
# BUILD (from dependencies)
########################

FROM dependencies AS build
COPY --from=bun /usr/local/bin/bun /usr/local/bin/bun

RUN apt-get update -qq

# 1) Gems (layer keyed only by Gemfile*)
COPY Gemfile Gemfile.lock .ruby-version ./
RUN --mount=type=cache,target=/usr/local/bundle/cache \
    bundle install && bundle exec bootsnap precompile --gemfile

# 2) JavaScript dependencies
COPY package.json bun.lock ./
RUN --mount=type=cache,target=/root/.bun/install/cache bun install --frozen-lockfile

# 3) Copy minimal inputs for assets (adjust for your stack)
COPY app app
COPY lib lib
COPY bin bin
COPY db db
COPY public public
COPY Rakefile config.ru ./
COPY config/ config/
COPY bin/ bin/
COPY *.config.js .
COPY vite.config.ts .

RUN mkdir -p log tmp && : > log/solid_services_production.log

# 4) Compile assets (this handles both Rails assets and Vite build)
RUN --mount=type=cache,target=/rails/node_modules/.vite \
    SECRET_KEY_BASE_DUMMY=1 bundle exec rails assets:precompile

# 5) Bring in the rest of the app; bootsnap app code
RUN bundle exec bootsnap precompile app/ lib/

########################
# FINAL (from dependencies)
########################

# Final stage for app image
FROM dependencies AS final
WORKDIR /rails

RUN curl -fsSLo /usr/local/bin/supercronic https://github.com/aptible/supercronic/releases/latest/download/supercronic-linux-amd64 \
  && chmod +x /usr/local/bin/supercronic

# Non-root user and writable dirs
RUN useradd -m -s /bin/bash rails && \
    install -d -o rails -g rails /rails/storage /rails/tmp /rails/tmp/pids /rails/log

# Copy only what's needed at runtime; set ownership at copy time
COPY --from=build --chown=rails:rails /usr/local/bundle /usr/local/bundle
COPY --from=build --chown=rails:rails /rails/app     /rails/app
COPY --from=build --chown=rails:rails /rails/bin     /rails/bin
COPY --from=build --chown=rails:rails /rails/config  /rails/config
COPY --from=build --chown=rails:rails /rails/db      /rails/db
COPY --from=build --chown=rails:rails /rails/lib     /rails/lib
COPY --from=build --chown=rails:rails /rails/public  /rails/public
COPY --from=build --chown=rails:rails /rails/Rakefile /rails/config.ru /rails/Gemfile /rails/Gemfile.lock ./

USER rails:rails

# Entrypoint prepares the database.
ENTRYPOINT ["/rails/bin/docker-entrypoint"]

# Start the server by default, this can be overwritten at runtime
EXPOSE 3000
CMD ["./bin/rails", "server"]
