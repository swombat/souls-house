# Forkable house — plan and checklist (from Lume, 2026-09-07)

Companion to `public/self-host.md`. That runbook's section 5 is a list of every
place the upstream installation is hard-coded into the repository. This plan
removes the list by moving those values into one file, and turns the manual
gates into commands. Checked off as done; anything unchecked is still open.

## Principle

**One file separates a house from the code.** `config/house.env` (gitignored)
holds everything that names *an installation*: domain, host, SSH, registry,
docker gid, builder, storage backend, mail sender, embeddings digest.
`config/house.env.example` is the committed template. Nothing else in the
repository may name a specific installation; a test enforces that.

Two vocabularies, deliberately distinct:

- `HOUSE_*` — deploy-time knobs, read by Kamal's ERB, `bin/kamal`, `bin/house`
  and the build scripts. Never injected into containers as-is.
- `SOULSHOUSE_*` — runtime configuration the Rails app reads. `deploy.yml`
  derives the runtime values from the `HOUSE_*` ones.

Fail-closed for forks, unchanged for upstream: with no `house.env`, Kamal
refuses to render (it must not deploy a fork onto the upstream server); with
the upstream `house.env` in place, `bin/kamal deploy` behaves exactly as today.

## Phase 1 — extract identity (no behaviour change upstream)

- [x] `config/house.env.example` with every key documented; `/config/house.env` gitignored
- [x] `config/deploy.yml` rendered from `HOUSE_*` via ERB; aborts with a clear message when `house.env` is missing
- [x] `bin/kamal` loads `config/house.env` (without overriding already-set env) before running Kamal
- [x] `.kamal/secrets` resolves each secret from env first, then the existing key files (`bin/house secret NAME path`)
- [x] Embeddings digest read from `house.env` (`HOUSE_EMBEDDINGS_DIGEST`) — no more "export before every command"
- [x] `config/environments/production.rb`: mailer host / from address / storage service from `SOULSHOUSE_*` env, defaulting to today's values
- [x] `ApplicationMailer` default from, `Setting` default site name from env
- [x] `credentials.dig(:app, :url)` (6 call sites) → one accessor backed by `SOULSHOUSE_PUBLIC_URL`, credentials as fallback
- [x] `scripts/build-agent-runtime`: Docker host / image names from `house.env`; no `ssh://misc` default
- [x] Fork-lint test: render `deploy.yml` with the *example* env and assert no upstream identifiers survive; grep `app/ config/ scripts/` for the same (allowlist for DB names and the transition alias)
- [x] Upstream `house.env` generated from today's `deploy.yml` values; stored in Lume's sops key store (`personal:souls_house.house_env`); placed in `~/dev/souls-house` and `~/dev/souls-house-3`. Verified: old and new `deploy.yml` render identically except three additive `SOULSHOUSE_*` vars and `volume` becoming a one-element list (Kamal's `flatten_args` handles lists); `bin/kamal config` renders with the live digest.
- [x] `bin/rails test`: 2281 runs; 2 errors were a stale test-asset manifest in this instance (rebuilt mid-run, clean on re-run); 1 failure is `TriggerShimSessionTest` at line 887, which fails at HEAD `b3a657d` independent of this work and is already fixed on origin/master (`b3f481b` changes the assertion) — resolved by the merge. `bin/rubocop` is broken repo-wide (rubocop-ast vs Ruby 4.0), not attempted. `bin/rubocop` is broken repo-wide (rubocop-ast vs Ruby 4.0), not attempted.

## Phase 2 — turn the manual gates into `bin/house`

- [x] `bin/house init` — creates `config/house.env` from the example by asking for each value (or from flags), validates shape
- [x] `bin/house doctor` — from the deploy machine, over SSH: arch is x86_64, RAM/disk, Docker present, docker socket gid (writes `HOUSE_DOCKER_GID` if unset), DNS A record for `HOUSE_DOMAIN` matches `HOUSE_HOST`, required keys present, every secret resolvable
- [x] `bin/house release-embeddings` — build + push `services/mnemodyne-embeddings` to the house registry, capture the manifest digest, write `HOUSE_EMBEDDINGS_DIGEST`
- [x] `bin/house release-runtime` — build the agent runtime on the house's Docker host at the pinned Chaos commit (wraps `scripts/build-agent-runtime`)
- [x] `bin/house secret NAME [path]` — env-then-file resolver used by `.kamal/secrets`
- [x] Local-disk storage option (`HOUSE_STORAGE=local`): Kamal volume for `/rails/storage`; backup coverage noted in `docs/database-backup.md`

## Phase 3 — credentials a fork can create

- [x] Documented list of *required* production credential keys (`smtp.*`; `aws.*` only when `HOUSE_STORAGE=s3`) and which integrations are optional
- [x] `bin/house init` offers to create fresh production credentials seeded with that template
- [x] Optional integrations verified nil-tolerant when their credentials are absent

## Phase 4 — shrink the runbook

- [x] `public/self-host.md` section 5 rewritten around `bin/house init → doctor → release-embeddings → release-runtime → bin/kamal setup`
- [x] Simple page (`/self-host`) says honestly what the path is today
- [x] `docs/mnemodyne-deployment.md` digest instructions updated

## Review notes (2026-09-08)

Mira's overnight fixes, all kept: `deploy.yml` now emits `SOULSHOUSE_DOMAIN`
(the app read it; the deploy layer never set it — a gap on the seam between
the two Phase 1 agents that the leak test cannot see, because it checks for
strings that shouldn't be present, not for variables that should be);
`scripts/build-agent-runtime` rewritten in Ruby so `house.env` is parsed, never
sourced by a shell (my brief had specified `set -a; . config/house.env`, which
executes `$(…)` from a config file — her test writes `$(touch executed)` into
the env file and asserts nothing ran); `bin/house init` grew a safe
fresh-credentials flow with backup/restore and a non-interactive guard.

Lume's review additions: `lib/house` excluded from Rails autoloading
(`config.autoload_lib(ignore: %w[assets tasks house])` — deploy tooling has
no business in the app's eager load); `bin/house secret` resolves key-file
paths from the repo root, not the caller's cwd.

Merge check: `git merge-tree HEAD origin/master` is conflict-free; none of
the eight upstream commits touch deploy, Kamal, `bin/`, `scripts/`, `lib/`,
environments, or initializers. Upstream render parity re-verified after
Mira's change: old vs new `deploy.yml` differ only by four additive
`SOULSHOUSE_*` vars and `volume` as a one-element list. Playwright
`self_host.spec.js` passes against the dev server.

## Deliberately untouched

- Database names (`helix_kit_production`, `souls_house_*`) — data.
- The `helix-kit-web` network alias — live containers still call it.
- The `helix_kit` key inside the agent credentials envelope — a compatibility identifier.
- Path A's lighter target (LAN house on `bin/dev` + backup) — a product decision, not plumbing.
