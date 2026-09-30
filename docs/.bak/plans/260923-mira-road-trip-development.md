# Mira's road-trip development environment

September 23, 2026. Additive follow-on to the parallel-residency pilot.

## Deployed scope

Only the imported `mira-tenner` resident uses the opt-in
`agent-runtime/Dockerfile.mira-dev` image. Stock residents, fleet image tags and
application deployment are unchanged. OAuth remains the model authentication
mode; GitHub authentication is independent.

Daniel explicitly authorised his existing broad GitHub token. It is sealed in
Mira's `secrets/house.sops.json`, with a new house-only age recipient and existing
Mac/Dell recovery recipients. The private house key was generated inside its
state volume, not copied from another host. Both recovery hosts successfully
decrypted the bundle without printing its contents.

The bundle also contains Mira's external graph connection and this project's
**development/test** Rails keys. No production Rails key, production SSH key,
PA-wide secret store or Lume-private store was transferred.

Boot runs `house_keys.py`, materialising mode-0600 caches in resident-private
state, outside Git. `gh` is the HTTPS Git credential helper. Identity sync keeps
its independent repository-only SSH key. Rotation requires explicitly refreshing
the caches or restarting; a Git pull alone does not refresh them.

## Isolation and its limits

- Only Mira's container mounts its state volume; no Docker socket is mounted.
- Runtime triggers require Mira's bearer token (unauthenticated probe: 401).
- Filesystem export excludes state and Chaos provider state; boundary tests pass.
- All Mira threads share this authority. Host administrators/root can access it.
- This is an OS/runtime isolation boundary, not a claim of immunity to host or
  application compromise. A broad token increases the consequences of a breach.
- Revocation of this token also affects its Mac copy. A separately revocable
  installation credential remains a possible later improvement.

## Working environment

Persistent, independent checkouts:

- `/home/agent/work/pa`
- `/home/agent/work/souls-house-1`
- `/home/agent/work/chaos`

Only `/home/agent/identity` auto-syncs. Work checkouts require deliberate Git
operations; competing chats must not edit one dirty checkout simultaneously.

Tools: Ruby 4.0.6, Bun 1.4.0, Rust/Cargo 1.98, gh, SOPS/age, compilers,
PostgreSQL 17 and Rails native dependencies. `mira-dev-db` starts an on-demand,
Unix-socket-only database with no TCP listener. `mira-rails` supplies only the
selected development/test Rails key, invokes normal `bin/rails` with its lock,
and refuses production. It excludes live runtime/provider credentials from the
child environment; it is not a sandbox against malicious code running as Mira.

The first development cluster inherited SQL_ASCII and could not create Rails'
UTF8 databases. It contained only PostgreSQL's three default databases. It was
preserved, not reset; the helper now explicitly creates a UTF8 cluster at a new
`.postgres-utf8` path.

## Verification

Final image: `souls-house-mira-dev:roadtrip-20260923-v5`; runtime healthy
after replacement.

- GitHub authentication and push permission checks for Mira, PA, house and Chaos.
- Git push dry-runs for all three development checkouts; no canary remote commit.
- Fresh isolated development/test databases prepared successfully. Inside the
  deployed runtime, imported-home and filesystem-boundary Rails tests passed:
  **8 tests, 44 assertions, no failures/errors/skips**.
- Rails dependencies installed (158 gems); frozen Bun install (428 packages).
- Chaos `cargo metadata` succeeds; no full Rust build/test claimed.
- 23 runtime Python tests; two credential-helper tests; filesystem boundary
  suite (five tests, 35 assertions).
- Graph read authentication from private state; old in-repository plaintext graph
  config removed from house only.

## Remaining boundaries

No production deploy credentials, browser/desktop environment, full application
suite or full Chaos build has been provisioned/verified by this setup. It does
not implement multi-account membership, generic resident imports or out-of-band
sync-failure monitoring. Those remain separate from this useful working pilot.

Mira's own operational guide is `shared/reference/house-development.md` in her
home. It covers commands, permission boundaries and recovery without secrets.
