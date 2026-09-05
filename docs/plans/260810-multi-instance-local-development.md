# Multi-Instance Local Development

**Status:** implemented and verified — 2026-09-05. See the operational guide for
verification results and the remaining application-level browser stress failure.
The original investigation below is retained as design history. The operational
contract and current names are in [the development guide](../multi-instance-development.md).
Key revisions: bounded IDs, fail-closed claims, browser/WebSocket cookie isolation,
Docker ownership labels, and no dependency on completing the internal rebrand.

**Date:** 2026-08-10

## Purpose

Allow several independent clones of the souls.house repository to run and test
at the same time without using Git worktrees.

The intended workflow is:

```text
souls-house      primary development instance
souls-house-1    one longer-running development stream
souls-house-2    another development stream
souls-house-3    another development stream
```

Each checkout should automatically get its own databases, ports, processes,
temporary artifacts, and — where hosted agents are involved — Docker resources.
This would allow work such as GitHub credential support and Telegram media
support to proceed concurrently without their test suites or development
servers interfering with one another.

This is environment isolation, not source-control conflict avoidance. Parallel
streams must still be divided sensibly and integrated deliberately.

## Why this should follow the internal rebrand

The implementation needs a central instance name and new environment variables.
Building that now around `HELIXKIT_*`, `helix_kit_*`, `hk-agent-*`, and the
`helixkit_agents` Docker network would either:

1. add more HelixKit names immediately before they are renamed; or
2. mix old and new naming schemes inside one infrastructure feature.

The existing rebrand plan already identifies the following Phase 2 work:

- repository and Docker image rename;
- Kamal service and network alias changes;
- `HELIXKIT_*` environment variable replacement;
- agent-runtime command compatibility;
- possible database naming decisions;
- Rails application module rename.

Multi-instance development should be designed against the names chosen by that
work. The rebrand does not necessarily need to rename the production database,
but the local instance prefix, environment variables, helper commands, Docker
resources, and documentation should use the settled souls.house terminology.

## Desired user experience

The checkout name supplies a default instance number:

| Checkout | Instance |
|---|---:|
| `souls-house` | 0 |
| `souls-house-1` | 1 |
| `souls-house-2` | 2 |

An explicit environment variable should override directory-name inference:

```sh
SOULS_HOUSE_INSTANCE=2 bin/dev
```

The exact variable spelling should be settled during the internal rebrand.

A diagnostic command should make the inferred configuration visible:

```sh
bin/instance show
```

Example output:

```text
Instance:       2
Rails URL:      http://localhost:3120
Vite URL:       http://localhost:3056
Development DB: souls_house_development_2
Test DB:        souls_house_test_2
Docker prefix:  souls-house-2
```

There should also be a safe setup command:

```sh
bin/instance setup
```

It should install or prepare checkout-local dependencies as needed and create
only the databases belonging to that instance. It must not drop, reset, or
otherwise rewrite the primary long-lived development database.

## Instance identity

Use one central instance configuration rather than independently parsing the
checkout name in Rails, shell scripts, Playwright, and Docker services.

Resolution order:

1. explicit instance environment variable;
2. recognised numeric suffix on the repository directory;
3. instance `0`.

The value should be validated as a small non-negative integer. Arbitrary clone
names should not silently become unbounded database names or invalid Docker
identifiers.

The primary instance should retain its existing unsuffixed resources wherever
practical. This avoids migrating or risking the current development database
just to add the feature.

## Port allocation

Do not simply add the instance number to every current port. The current
configuration already places the Rails development server on 3100 and the
Playwright component server on 3101, so naive incrementing would cause instance
1's Rails server to collide with instance 0's component tests.

Allocate a block of ports per instance:

| Resource | Instance 0 | Instance 1 | Instance 2 |
|---|---:|---:|---:|
| Rails development | 3100 | 3110 | 3120 |
| Playwright component | 3101 | 3111 | 3121 |
| Vite development | 3036 | 3046 | 3056 |
| Vite test | 3037 | 3047 | 3057 |
| Playwright Rails backend | 3200 | 3210 | 3220 |

This preserves the current primary ports while reserving enough space for each
instance's cooperating processes.

`bin/dev` already exports a configurable Rails port. Vite Ruby 3.9.2 also
supports a `VITE_RUBY_PORT` environment override. These should be populated by
the shared instance configuration rather than adding generated per-clone
configuration files.

The following fixed URLs or ports also need to become instance-aware:

- development mailer URL generation;
- agent credential application URL fallback;
- Playwright E2E base URL;
- Playwright component base URL and proxy targets;
- Playwright component server port;
- test backend scripts;
- documentation and browser examples.

## PostgreSQL isolation

The current application has four development databases:

- primary;
- Solid Cache;
- Solid Queue;
- Solid Cable.

It also has a test database, with Rails creating additional worker databases
when Minitest runs in parallel.

Every base database name must include the instance suffix before Rails applies
its parallel-test worker suffixes.

Conceptually:

```text
souls_house_development
souls_house_development_cache
souls_house_development_queue
souls_house_development_cable
souls_house_test

souls_house_development_1
souls_house_development_1_cache
souls_house_development_1_queue
souls_house_development_1_cable
souls_house_test_1
```

The final word order is less important than calculating it consistently in one
place.

This is necessary even when no development server is running: two ordinary
`bin/rails test` commands in separate clones currently share the same test
database namespace.

## Filesystem and process isolation

Most Rails resources are already checkout-local:

- `tmp/pids`;
- Rails logs;
- Active Storage development files;
- Vite build output;
- `node_modules`;
- Playwright reports and test results.

These do not need new global namespaces as long as each stream uses a real clone
rather than a worktree sharing generated files.

Some scripts currently write to fixed global paths or act on fixed ports. In
particular, the E2E runner writes to:

```text
/tmp/helix-kit-playwright-e2e.log
```

That should become instance-specific or, preferably, checkout-local.

Older Playwright helper scripts also kill whatever process owns port 3200.
They should instead record and stop only the PID they started. One instance
must never clean up another instance's server by searching globally by port.

## Hosted-agent Docker isolation

This is the main difference between ordinary Rails clone isolation and a fully
independent souls.house instance.

Hosted agents currently use globally visible Docker resources whose names are
derived from agent UUIDs:

- agent containers;
- identity volumes;
- Chaos home volumes;
- repository volumes;
- work volumes;
- state volumes;
- the shared agent network;
- the local agent-runtime image tag.

Randomly published host ports are already safe, but the resource names are not.

Create one naming service responsible for every Docker name. Do not append
instance suffixes independently throughout `Agents::Sandbox`,
`Agents::Volume`, `Agents::VolumeSet`, provisioning, diagnostics, filesystem
inspection, and backup/restore code.

Conceptually:

```text
Instance 0:
  souls-agent-<uuid>
  souls-agent-<uuid>-identity
  souls-agents
  souls-agent-runtime:local

Instance 1:
  souls1-agent-<uuid>
  souls1-agent-<uuid>-identity
  souls-agents-1
  souls-agent-runtime:local-1
```

The exact format should follow the internal rebrand's final Docker naming.

Namespacing the local image matters if two streams modify `agent-runtime/`.
Otherwise one clone rebuilding the shared `:local` image could silently change
the runtime beneath agents belonging to another clone.

## Development data policy

Secondary instances should receive a **fresh development database by default**,
created from the schema and safe seed data.

Do not automatically clone the primary development database. The primary
database contains long-lived and externally meaningful state, potentially
including:

- hosted-agent UUIDs and stored container names;
- pointers to persistent Docker volumes;
- agent endpoint URLs and bearer tokens;
- Telegram bots, subscriptions, and webhook state;
- API keys and service credentials;
- queued jobs;
- external integration state.

A direct database copy would duplicate logical ownership of those resources.
Even with Docker name prefixes, a copied secondary instance could send external
messages, run background work, or present stale runtime records as live.

If copying development data later proves valuable, implement it as a separate,
explicit operation:

```sh
bin/instance data clone --from primary
```

That operation would need a documented sanitisation pass which at minimum:

- disables hosted runtimes;
- clears runtime endpoints and container ownership;
- removes or disables queued work;
- disconnects Telegram webhooks and other single-owner integrations;
- removes or replaces secrets;
- prevents scheduled or outbound side effects;
- clearly marks the resulting database as cloned development data.

This should not be part of the first implementation.

## External services that cannot be isolated automatically

Some resources exist outside the local machine and cannot be made independent
merely by changing ports:

- a Telegram bot can have only one active webhook;
- OAuth applications have registered callback URLs;
- ngrok or other tunnel hostnames may be single-owner;
- email and API credentials may carry real-world side effects;
- remote agent repositories and backup repositories are globally shared.

Fresh secondary databases avoid most accidental use. Testing an integration
against multiple live instances may still require separate test credentials,
bots, applications, or tunnel URLs.

The instance diagnostic should make this limitation visible rather than imply
that every external account has been cloned safely.

## Credentials and dependencies

Local credential keys are ignored by Git, so a new clone will not necessarily
boot merely because the repository itself was cloned.

`bin/instance setup` should either:

- explain which local credential files must be copied from the primary
  checkout; or
- support an explicit, narrow command for copying only the required local
  development/test keys.

It should not copy arbitrary `.env` files or secret material silently.

Ruby gems may remain shared through the user's Ruby installation. Keep
`node_modules` checkout-local by default: sharing it would reintroduce
interference when two streams change JavaScript dependencies.

## Git workflow

Separate clones solve runtime and filesystem collisions but do not solve merge
conflicts.

The cleanest operating model is one branch per clone:

```text
souls-house      master
souls-house-1    github-token-support
souls-house-2    telegram-media
```

When a stream is ready:

1. update it from current master;
2. resolve conflicts within that stream;
3. run its isolated tests;
4. merge or fast-forward it deliberately;
5. update the remaining streams from the new master.

Running several divergent local branches all named `master` would be possible
but unnecessarily confusing. The repository's branch guidance will need an
explicit exception or revision for this workflow.

## Proposed implementation phases

### Phase 1 — Application and test isolation

- central instance resolver;
- checkout suffix and explicit override;
- per-instance development and test database names;
- per-instance Rails and Vite ports;
- dynamic development URLs;
- Playwright port, PID, and log isolation;
- `bin/instance show`;
- safe `bin/instance setup`;
- tests for naming and configuration;
- developer documentation.

This phase is sufficient for simultaneous application development and test
runs, including the GitHub-token and Telegram-media example.

### Phase 2 — Complete hosted-agent isolation

- central Docker resource naming service;
- per-instance containers, networks, and all volume types;
- per-instance local runtime image tags;
- provisioning and endpoint integration;
- diagnostics and filesystem inspection integration;
- backup and restore integration;
- safety tests proving one instance cannot address another's resources.

Do not describe the feature as a fully separate souls.house instance until this
phase is complete.

### Possible later phase — Sanitised data cloning

- explicit clone command;
- safe snapshot/copy mechanism;
- sanitisation transaction;
- external integration disconnection;
- strong confirmation and source/destination diagnostics.

## Likely files and areas

The exact names will change during the rebrand, but implementation is likely to
touch:

- `bin/dev`;
- a new `bin/instance` helper;
- `Procfile.dev`;
- `config/database.yml`;
- `config/vite.json` or Vite environment setup;
- `config/environments/development.rb`;
- Playwright configurations and runner scripts;
- agent runtime configuration;
- hosted-agent provisioning;
- Docker container and volume naming;
- local runtime image building;
- agent diagnostics and filesystem inspection;
- agent backup and restore services;
- repository development and safety documentation;
- focused tests for all calculated names and ports.

## Acceptance criteria

For instances 0, 1, and 2 running concurrently:

- each development server is reachable on its documented URL;
- each Rails server connects only to its own four development databases;
- each Rails test command uses only its own test and worker databases;
- each Vite server uses its own port;
- each Playwright run starts and stops only its own backend;
- logs and reports do not overwrite another instance's artifacts;
- mailer and generated local application URLs point to the correct instance;
- agent callbacks return to the correct Rails instance;
- Docker containers, networks, volumes, and local runtime images do not overlap;
- stopping or cleaning one instance leaves the others running;
- the primary long-lived development database is unchanged;
- the diagnostic command accurately reports all selected resources.

## Recommendation

Finish enough of the internal rebrand to settle:

- repository and checkout name;
- environment variable prefix;
- local database prefix;
- Docker container, volume, network, and image naming;
- agent-runtime compatibility names.

Then implement Phase 1 and Phase 2 together as one coherent local-instance
feature, while keeping sanitised data cloning explicitly out of scope.
