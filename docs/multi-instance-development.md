# Multiple local souls.house instances

Use **independent clones**, each with one stable instance number, for parallel
work. No production resources or primary development data are copied.

## Start a second stream

```sh
cd ~/dev
git clone <the-souls-house-repository-url> souls-house-1
cd souls-house-1
# Review mise.toml before trusting it. It pins Ruby and Bun.
mise trust && mise install
mise exec -- bin/instance setup --credentials-from ../souls-house
mise exec -- bin/instance show
mise exec -- bin/dev
```

Repeat with `souls-house-2`. Setup copies **only missing development/test
credential keys**, explicitly requested by `--credentials-from`. It never copies
production keys, `.env`, application data, Docker identities, or provider homes.
Without that option, provision the development/test keys yourself. Ruby gems may
be shared; JavaScript dependencies, uploads, assets, PID files and logs are local
to each clone. Setup rejects mismatched Ruby/Bun versions before installation.

| Checkout | Rails | Vite | Browser-test Rails | Component tests |
|---|---:|---:|---:|---:|
| souls-house | 3100 | 3036 | 3200 | 3101 |
| souls-house-1 | 3110 | 3046 | 3210 | 3111 |
| souls-house-2 | 3120 | 3056 | 3220 | 3121 |

Numbers **0–9 only**. `SOULSHOUSE_INSTANCE=3` overrides inference; unknown directory
names otherwise fail closed. Set an override consistently for *all* commands in
that checkout, not just `bin/dev`. Do not run different instance numbers from one
checkout: its generated artifacts would still be shared.

Instance 0 retains its existing `helix_kit_*` databases and development Docker
names. Secondary instances use `souls_house_development_N`, its `_cache`, `_queue`
and `_cable` databases, and `souls_house_test_N` with Rails' `-WORKER` suffixes.
Local database URL overrides are rejected before Rails connects. Production
configuration is not instance-resolved.

## Tests and process ownership

```sh
mise exec -- bin/rails test
mise exec -- bun run test           # E2E with an owned Rails test backend
mise exec -- bun run test:ct        # component suite with an owned backend
```

Run commands from their checkout. Ordinary `bin/rails test` and the browser
runners take the same checkout-local test lock. One test runner per checkout;
parallel Minitest workers within that runner are supported. Development can stay
running while tests run. For other test entrypoints, use
`bin/instance exec test -- <command>` (and `SOULSHOUSE_TEST_LOCKED=1` if wrapping
`bin/rails test` itself). Raw `bundle exec rake test` bypasses the runner lock.

Occupied ports fail rather than being reused or killed. Test readiness verifies
both checkout identity and a per-launch token. Cleanup signals only owned child
processes; there is no port-based kill, global log, or database reset. Logs are in
`log/playwright-*.log`. Browser reports remain checkout-local. Vite uses strict
ports. Web authentication, Rails session cookies, and Action Cable authentication
use the same instance-aware identity; two localhost ports can stay logged in in
one browser.

The component suite is older and has its own UI expectations; environment
isolation does not guarantee every pre-existing assertion matches today's UI.

## Identity claims

First boot records an instance-to-checkout claim under
`~/.local/state/souls-house/instances/N.json`. All Rails entrypoints and Vite check
it, including consoles and database tasks. A second clone cannot silently reuse
an occupied identity even when neither web server is running.

Claims deliberately survive exit. To retire or move a checkout, stop its
processes and decide what to do with its databases/Docker volumes first. Then
remove **only its matching claim file**, and assign the identity deliberately.
Do not delete another active checkout's claim to get past the guard. Existing
Docker ownership labels also bind resources to their original checkout path;
moving persistent hosted identities requires a deliberate migration, not a
renamed directory or copied database.

## Hosted runtimes

Before promoting a synthetic resident in a secondary instance, prepare its image:

```sh
# Rebuild from this checkout's agent-runtime/; tags only this instance's image.
mise exec -- scripts/build-local-agent-runtime

# Or explicitly snapshot an already-built local image, without rebuilding:
mise exec -- scripts/build-local-agent-runtime --from helixkit-agent-runtime:local
```

The latter takes the source's immutable image ID and gives it an independent tag.
Rebuilding either tag later does not move the other. Never use
`scripts/build-agent-runtime` for this: that remains the **deployment** builder
and defaults to a remote Docker host and deployment tags.

Containers, all five volume types, and networks are namespaced by instance and
Rails environment. Test resources are separate even from the same instance's
development resources. Local application Docker operations require a Unix-socket
Docker endpoint, validate stored container names, and check ownership labels
before addressing isolated resources. Unknown/unlabelled resources are rejected,
not adopted. Production and primary development preserve existing names.

Diagnostics, filesystem/journal inspection, storage measurement and cleanup use
these same ownership checks. Local runtime callbacks use that instance's development or test-backend
port, matching the Rails environment. Conflicting explicit callback URL overrides
are rejected for secondary instances. External backup/restore operations are **disabled for secondary/test
instances**; copying real hosted identities is intentionally not implemented.

Optional real-Docker safety smoke test (synthetic busybox containers only):

```sh
mise exec -- scripts/verify-instance-docker
```

It verifies separate containers/networks/volumes, rejected foreign ownership,
and stopping one instance without stopping another. It removes its own resources.
It does not invoke an agent or access a resident identity.

## Source control and integrations

Environment isolation is not merge-conflict avoidance. Keep streams disjoint,
integrate one at a time into `master`, test the integrated result, then update the
other clones. Follow `AGENTS.md`: feature branches still require explicit user
instruction; cloning is not implicit permission to change that policy.

Fresh development databases have no users or residents: create local accounts
through signup. They do not inherit the primary instance's long-lived data.
No automated data-cloning command is provided. `bin/instance setup` intentionally
refuses instance 0; existing primary setup remains an explicit separate action.

Telegram bots/webhooks, OAuth registrations, tunnels, remote repositories, email
and API credentials are **not** isolated by local namespaces. Use dedicated test
integrations. Decrypting shared development credentials is not permission to use
live services. No automatic launch of hosted residents is performed by setup.

## Verification record — 2026-09-05

- Full Rails suite: **2,484 tests, 11,872 assertions, zero failures/errors**.
- Instances 1 and 2: simultaneous Rails tests, independent four-database development
  stacks, Vite and Solid Queue processes, plus simultaneous browser suites.
- Full E2E suite: 16/16 passed on instance 2. Instance 1 reached 15/16; the
  simultaneous-writers stress test intermittently loses a submitted message.
  It passed on an isolated rerun, but remains an application-level follow-up,
  not a suppressed test.
- Same-browser smoke: different users stayed logged in across two localhost
  ports; logout on one did not log out the other.
- Real Docker smoke: ownership rejection, independent volumes/networks/containers,
  and stop isolation passed. Full E2E hosted promotion also passed on both clones.
- Stopping an owned test backend left the other test backend and both development
  stacks running. No primary database reset, import or migration was performed.
- Stock RuboCop cannot parse the repository's Ruby 4.0 target with its pinned
  parser version. Changed Ruby files pass using a temporary Ruby 3.4 parser target;
  no repository lint rule was weakened. The repository-wide frontend format check
  reports eight pre-existing files outside this change; changed JS/config files
  were formatted separately.

To repeat the browser-cookie smoke, start `playwright/setup-test-server.sh` in
both secondary checkouts, then run from either checkout:

```sh
mise exec -- node scripts/verify-instance-browser.mjs http://127.0.0.1:3210 http://127.0.0.1:3220
```

Stop those test backends before running other tests in the same checkouts.
