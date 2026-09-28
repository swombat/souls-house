# Repository Guidelines

Before major work, read `docs/architecture.md` and `docs/decisions/README.md`; follow the reviewed issue/PR and deployment gates in ADR 0002.

## Project Structure & Module Organization
souls.house couples Rails 8 and Svelte 5 through Inertia. Domain models live in `app/models`, controllers in `app/controllers`, and jobs in `app/jobs`. Frontend primitives and patterns stay under `app/frontend`, with styles in `app/frontend/styles`. Configuration belongs inside `config`, and `docs/overview.md` points to current architectural guides. Historical plans and reviews are in `docs/.bak/` and are not implementation instructions; `docs/proposals/` is explicitly unimplemented discussion.

## Build, Test, and Development Commands
Run `bin/dev` to launch Rails, Vite, and the Solid* services on http://localhost:3100. Keep schemas up to date with `bin/rails db:prepare` and migrate via `bin/rails db:migrate && bin/rails db:schema:dump`. Frontend tooling runs through Bun: `bun install`, `bun run test:unit` (Vitest), `bun run test` (Playwright E2E). Use `bin/rails test` or narrow scope, e.g. `bin/rails test test/models/user_test.rb`.

## Coding Style & Naming Conventions
Write as though you are DHH shipping code into Rails core: choose the boring, conventional solution, prefer readability over cleverness, and rely on Rails helpers before building abstractions. Ruby follows RuboCop (`bin/rubocop`), two-space indent, snake_case methods, PascalCase classes. Keep models lean; push orchestration into POROs under `app/lib` or concerns. Svelte components use kebab-case filenames (`user-menu.svelte`), camelCase props, and Tailwind utility classes; format with `bun run format` / `bun run format:check`.

## DHH Mode Checklist

For Svelte boundaries and file-size thresholds, follow `docs/frontend-components.md`:
review components/layouts above 200 lines and pages above 300; ceilings are 300
and 500 respectively. Run `bun run check:svelte-size`. Reuse is not required for
a coherent section to become a component; keep Inertia pages as pages.

1. Ask “How would Rails solve this today?” before adding gems or custom JS.
2. Pretend future maintainers are Rails core reviewers—ship code they would merge.
3. If a solution feels clever, rewrite it straighter and document any intentional divergence from convention.

## Testing Guidelines
Minitest lives in `test/`; mirror Rails naming such as `accounts_controller_test.rb` and lean on fixtures in `test/fixtures`. Co-locate Vitest specs beside Svelte sources as `*.test.ts`. Playwright journeys reside in `playwright/tests`; always run them via the provided scripts and never touch the dev database destructively. Expand coverage with each feature and share factories instead of hard-coded records.

## Commit & Pull Request Guidelines
Use short, imperative commit subjects (<72 chars) like `Add chats index pagination`, grouping related work. Reference issues in the body when useful. PRs need a problem summary, UI screenshots when visuals change, and explicit notes on migrations or secrets. Run `bin/rubocop`, `bun run format:check`, `bin/rails test`, and `bun run test` before requesting review.

## Branch Policy
For major work, follow ADR 0002: an issue approved by the other author, a dedicated
PR branch, then reciprocal review of the PR head before merge into `master`.
Daniel explicitly authorised this process on 2026-09-28; it supersedes the former
mainline-only rule for these changes. Verify your branch and scope before every
commit/push. Do not commit implementation directly to `master` to bypass review,
and do not create worktrees or unrelated branches without authorisation.

## Parallel Local Development
Independent clones named `souls-house-1` through `souls-house-9` are supported.
Read `docs/multi-instance-development.md` before setting one up. Use the pinned
Ruby/Bun versions, `bin/instance setup`, and the normal `bin/rails test` / browser
runners; do not bypass ownership guards or copy the primary database. This does
not change the branch policy above. Prefer one coding agent per instance. If a
test lock is held, wait or use another clone; never delete the lock file to bypass
a running process.

## Environment & Safety
The shared development database is long-lived—never run `rails db:drop`, `db:reset`, or mass `destroy_all`. Leave the existing `bin/dev` process running instead of killing its PID in `tmp/pids`. Manage secrets with `config/credentials.yml.enc` and consult `docs/` before altering infrastructure or dependencies. Installation identity (domain, host, SSH, registry, docker gid, storage backend, embeddings digest) lives only in gitignored `config/house.env`, with `config/house.env.example` as the committed template—never hard-code a host, domain, registry, or IP anywhere else. `test/house/identity_leak_test.rb` fails the suite on a violation; its allowlist is where a legitimate exception gets recorded, with its reason. Deploying needs `house.env` present; run `bin/house doctor` to check.

## Chaos Runtime: Upstream First
We have write access to `seuros/chaos`. General-purpose Chaos fixes and useful
runtime functionality belong in that repository, through focused issues and PRs,
not a persistent patch stack in souls.house. Read Chaos's current
`docs/contributing.md` before contributing; write access does not bypass review,
tests, or authorship/sign-off requirements.

Use a pinned upstream commit in `agent-runtime/chaos-ref`. Local patches are an
exception only when absolutely necessary to unblock an urgent problem: document
the reason, upstream issue/PR, owner, and removal condition. Remove the exception
as soon as the upstream fix is available. Do not discard a working fix before its
replacement is verified. Review the complete build graph before expensive builds;
compile the final source once, never append patch-and-rebuild layers.
