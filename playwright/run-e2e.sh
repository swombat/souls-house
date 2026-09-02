#!/bin/bash

set -e

export RAILS_ENV=test
export NODE_ENV=test
export PLAYWRIGHT_BASE_URL="${PLAYWRIGHT_BASE_URL:-http://127.0.0.1:3200}"

PORT="${PLAYWRIGHT_BASE_URL##*:}"
PORT="${PORT%%/*}"

cleanup() {
  if [ -n "$RAILS_PID" ]; then
    kill "$RAILS_PID" 2>/dev/null || true
  fi
}

trap cleanup EXIT INT TERM

echo "Preparing test database..."
bin/rails db:prepare

echo "Building test assets..."
bin/vite build --mode test >/dev/null

echo "Starting Rails test server on ${PLAYWRIGHT_BASE_URL}..."
bin/rails server -e test -p "$PORT" -b 127.0.0.1 >/tmp/helix-kit-playwright-e2e.log 2>&1 &
RAILS_PID=$!

for attempt in {1..30}; do
  if curl -s -o /dev/null -w "%{http_code}" "$PLAYWRIGHT_BASE_URL/up" | grep -q "200"; then
    break
  fi

  if [ "$attempt" -eq 30 ]; then
    echo "Rails server did not become ready. Recent log output:"
    tail -100 /tmp/helix-kit-playwright-e2e.log
    exit 1
  fi

  sleep 1
done

bun x playwright test -c playwright-e2e.config.js "$@"
