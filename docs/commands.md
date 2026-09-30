# Development commands

Use the repository's pinned Ruby and Bun versions from [mise.toml](../mise.toml).
Run from the intended checkout. For a new independent clone, follow
[multi-instance setup](multi-instance-development.md); do not copy databases,
provider homes or production configuration.

## Development and database safety

```sh
bin/dev                         # Rails, Vite and development services
bin/instance show               # Inspect this checkout's instance identity
bin/rails db:prepare             # Prepare the intended local database
bin/rails db:migrate             # Apply reviewed migrations
bin/rails db:schema:dump         # Refresh schema after a migration
bin/rails routes                # Inspect implemented routes
```

The primary development Rails port is 3100; secondary instance ports are offset.
Keep an existing `bin/dev` supervisor running. Use `bin/rails restart` for its Puma
worker when necessary rather than killing unrelated processes.

**Never reset/drop/reseed an existing development database, load a replacement
schema over it, truncate tables or bulk-delete real records.** `db:setup` is not an
upgrade command. See [database safety](database-safety.md). Avoid destructive
“reset everything” recipes and console credential dumps.

## Test and quality checks

```sh
bin/rails test                                  # Rails suite (ownership locked)
bin/rails test test/models/user_test.rb         # Focused Rails file
bin/rails test:system                           # Rails system/browser suite
bun run test:unit --run                         # Vitest, one pass
bun run test                                   # Playwright E2E, owned Rails backend
bun run test:ct                                # Playwright component suite
python3 -m unittest discover -s test -p '*_test.py'
python3 -m unittest discover -s test/runtime -p '*_test.py'
bin/rubocop
bun run format:check
```

Rails and browser test commands serialize use of a checkout's test database. Never
remove a held lock or bypass the runner with raw `rake test`. Browser runners own
their test backend and clean up only their processes. Tests must not inherit live
resident/provider credentials. See [testing](testing.md),
[browser testing](playwright-testing.md) and [CI](continuous-integration.md).

For this documentation-only tree, check relative links, moved-path references and
`git diff --check` too. Historical files in `.bak` are not current link/format
contracts. Runtime-installed manuals live under `agent-runtime/docs`; do not move
them merely to make the top-level index look tidy.

## Dependencies and assets

```sh
bundle install
bun install --frozen-lockfile
bin/vite build
```

Do not update dependencies as an incidental part of a documentation or bug fix.
Commit lockfile changes only when they belong to the task.

## Operations are separate

[Self-hosting](../public/self-host.md) documents `bin/house` and deployment;
[backup](database-backup.md) covers recovery. Installation identity belongs in
`config/house.env` using the committed template. Production commands, credential
changes, restores and real resident invocations require their own authorization;
none is a routine documentation-validation step.
