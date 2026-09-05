#!/usr/bin/env sh
set -eu
cd "$(dirname "$0")/.."
exec bin/instance exec test -- ruby playwright/run-backend.rb ct "$@"
