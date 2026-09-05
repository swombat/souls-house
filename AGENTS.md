# Repository Guidelines

## Project Structure & Module Organization
Helix Kit couples Rails 8 and Svelte 5 through Inertia. Domain models live in `app/models`, controllers in `app/controllers`, and jobs in `app/jobs`. Frontend primitives and patterns stay under `app/frontend`, with styles in `app/frontend/styles`. Configuration belongs inside `config`, and `docs/overview.md` points to deeper architectural guides.

## Build, Test, and Development Commands
Run `bin/dev` to launch Rails, Vite, and the Solid* services on http://localhost:3100. Keep schemas up to date with `bin/rails db:prepare` and migrate via `bin/rails db:migrate && bin/rails db:schema:dump`. Frontend tooling runs through Bun: `bun install`, `bun run test:unit` (Vitest), `bun run test` (Playwright E2E). Use `bin/rails test` or narrow scope, e.g. `bin/rails test test/models/user_test.rb`.

## Coding Style & Naming Conventions
Write as though you are DHH shipping code into Rails core: choose the boring, conventional solution, prefer readability over cleverness, and rely on Rails helpers before building abstractions. Ruby follows RuboCop (`bin/rubocop`), two-space indent, snake_case methods, PascalCase classes. Keep models lean; push orchestration into POROs under `app/lib` or concerns. Svelte components use kebab-case filenames (`user-menu.svelte`), camelCase props, and Tailwind utility classes; format with `bun run format` / `bun run format:check`.

## DHH Mode Checklist
1. Ask “How would Rails solve this today?” before adding gems or custom JS.
2. Pretend future maintainers are Rails core reviewers—ship code they would merge.
3. If a solution feels clever, rewrite it straighter and document any intentional divergence from convention.

## Testing Guidelines
Minitest lives in `test/`; mirror Rails naming such as `accounts_controller_test.rb` and lean on fixtures in `test/fixtures`. Co-locate Vitest specs beside Svelte sources as `*.test.ts`. Playwright journeys reside in `playwright/tests`; always run them via the provided scripts and never touch the dev database destructively. Expand coverage with each feature and share factories instead of hard-coded records.

## Commit & Pull Request Guidelines
Use short, imperative commit subjects (<72 chars) like `Add chats index pagination`, grouping related work. Reference issues in the body when useful. PRs need a problem summary, UI screenshots when visuals change, and explicit notes on migrations or secrets. Run `bin/rubocop`, `bun run format:check`, `bin/rails test`, and `bun run test` before requesting review.

## Branch Policy
Work directly on the mainline `master` branch by default. Do not create, switch to, publish, or use temporary feature branches or worktrees unless the user explicitly instructs you to. Before committing or pushing, verify that the current branch is `master`.

## Parallel Local Development
Independent clones named `souls-house-1` through `souls-house-9` are supported.
Read `docs/multi-instance-development.md` before setting one up. Use the pinned
Ruby/Bun versions, `bin/instance setup`, and the normal `bin/rails test` / browser
runners; do not bypass ownership guards or copy the primary database. This does
not change the branch policy above.

## Environment & Safety
The shared development database is long-lived—never run `rails db:drop`, `db:reset`, or mass `destroy_all`. Leave the existing `bin/dev` process running instead of killing its PID in `tmp/pids`. Manage secrets with `config/credentials.yml.enc` and consult `docs/` before altering infrastructure or dependencies.
