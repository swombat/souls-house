# Full-suite CI on standard public runners

This is an internal tooling change, not a production deployment. Public
repositories can use standard GitHub-hosted runners without buying Actions
minutes. Runner concurrency is account-wide; it also serves deployment jobs.
Do not solve one workflow's latency by filling the entire pool.

## Tooling image

`.github/ci/Dockerfile` builds only pinned tools and system/browser dependencies.
Its context contains no application source or credentials. Ruby and Bun must
match the application's pins; Playwright must match both packages in `bun.lock`.
The standalone image contract treats drift as a failure.

The separate **CI tooling image** workflow validates PR image changes by
building, installing the real locked gems in an ephemeral container, and
launching Chromium. Only dependency manifests are mounted read-only for that
native-gem check, not the application or its credentials.
Publication is restricted to trusted `master`
pushes or explicit `master` dispatches. Only the publishing job receives
`packages: write`; PR test jobs remain `contents: read`.

Before changing normal CI to a new image:

1. Review and merge the tooling change.
2. Wait for its publication and take the immutable digest from the job summary.
3. Make the package public if this is its first publication.
4. Verify a pull without registry credentials; a successful authenticated pull
   does not prove fork PRs can use it.
5. Review the consumer workflow's digest change and run the complete suites.

Keep the previous digest for rollback. Do not delete it just because a new
image has built successfully. Do not add publication secrets to test jobs to
work around a private package.

Every image change therefore has two steps: merge/publish the tooling-only
change first, then update and test the consumer digest in a follow-up PR.

## Partition and coverage contracts

Rails uses `scripts/run-rails-shard.rb SHARD TOTAL`. Its discovery mirrors the
ordinary Rails test runner. Cross-test loads are grouped together, including
transitive dependencies through support files, to avoid replaying tests in
another shard. Dynamic loads fail closed. Groups are greedily balanced by
source byte size with deterministic tie-breaking; this is a starting heuristic,
not observed duration data.

Empty shards exit without invoking bare `bin/rails test`, which would otherwise
run the entire suite. System tests are excluded from the ordinary partition and
run exactly once on Rails shard 1. Each job owns its checkout, database and
normal instance/test lock; do not run competing outer shards inside one local
instance or bypass its lock.

The E2E partition uses Playwright's native file sharding, all projects, one
worker and `--no-deps`. This avoids re-running the full Chromium dependency
project when admission is selected. Admission tests alter global backend
settings, so they must be serial with other tests on their shard and isolated
from other shards by a separate backend/database. Local project dependencies
remain unchanged.
The listing contract also requires admission to be last on its assigned shard,
so rebalancing cannot silently reverse the former project ordering. The test's
existing `finally` restores its setting; ordering is an additional guard, not
a replacement for restoration.

Contracts:

```sh
bundle exec ruby test/ci/rails_sharding_contract.rb
node test/ci/browser-sharding-contract.mjs
python3 -m unittest discover -s test/ci -p '*_test.py'
```

The browser contract lists tests without starting a browser/backend. It compares
the complete baseline with the shard union, checks uniqueness and whole-file
assignment, and confirms admission coverage. Listing proves assignment, not
that hidden load-order assumptions or individual tests are correct: the entire
partition still has to run.

## Measure, then adjust

Compare successful runs on the same source, including provisioning, asset
build, backend startup, test execution, retries and the final aggregate check.
Separate queue delay from execution but report both when describing what a
person waited for. Jobs run concurrently; do not sum their elapsed durations.

The initial consumer graph is nine jobs: two Rails shards at four workers,
three serial E2E shards, the full component suite, frontend, Python, and an
aggregate result. Two complete runs plus a deployment fit within twenty slots,
absent other account workflows. This is headroom, not a reserved deployment
slot or a guarantee against queueing.

Do not silently drop suites or retries to meet the two-minute target. Check
executed test counts against the source revision's discovery, not just a
historical number. If a long file sets the tail, inspect its duration before
changing parallelism or splitting it. Asset reuse must be tied to all relevant
build inputs; a generic "skip build" flag risks serving stale code.

Container jobs connect to the service hostname `postgres`, not host loopback.
They use `--ipc=host` for Chromium. Browser tests run in an ephemeral root
container using Playwright's normal sandbox-disabled launch, with no production
or provider credentials; this is not a production-browser security policy.
