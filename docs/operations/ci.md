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
measured seconds per file (`test/ci/rails_timings.json`) with deterministic
tie-breaking; a file without a time is weighted by its size at the measured
suite's seconds per byte. To refresh the measurements after the suite has
changed shape, run the whole suite once with `bin/test` (padded_cell records
every test's time in `tmp/padded_cell/timings.tsv`) and then
`ruby scripts/rails-test-timings.rb`. The Rails contract fails once fewer than
80% of the files have a time.

Empty shards exit without invoking bare `bin/rails test`, which would otherwise
run the entire suite. System tests are excluded from the ordinary partition and
run exactly once on Rails shard 1. Each job owns its checkout, database and
normal instance/test lock; do not run competing outer shards inside one local
instance or bypass its lock.

The E2E partition is a list of whole spec files per shard from
`scripts/e2e-shard.mjs SHARD TOTAL`, balanced by the seconds in
`test/ci/e2e_timings.json` (a new file counts as the median). Playwright's own
`--shard` cuts the alphabetical file list into equal numbers of tests, which
left one shard at 389 s and another at 253 s. Each shard runs all projects,
one worker and `--no-deps`, which avoids re-running the full Chromium
dependency project when admission is selected. Admission tests alter global
backend settings, so they must be serial with other tests on their shard and
isolated from other shards by a separate backend/database. Local project
dependencies remain unchanged. To refresh the measurements, run the suite with
Playwright's JSON reporter and feed the report(s) to
`node scripts/e2e-test-timings.mjs`.
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

## Asset build reuse

Every container job needs `public/vite-test`, and building it takes about a
minute. The workflow restores `public/vite-test` and `tmp/cache/vite` from
`actions/cache` under a key that hashes everything the build reads
(`app/frontend`, the views and helpers Tailwind scans, the Vite and package
configs, the lockfile, the tooling image). `tmp/cache/vite` holds vite_ruby's
own digest of the same inputs (`watchAdditionalPaths` in `config/vite.json`
adds the views, helpers and `bun.lock` to its default watch list), so on a hit
`bin/vite build --mode test` finds the build current and skips, and on a miss
or any drift between the two lists it builds. There is no "skip build" flag:
`playwright/run-backend.rb` runs the same build command as the Rails shards.

## Measure, then adjust

Compare successful runs on the same source, including provisioning, asset
build, backend startup, test execution, retries and the final aggregate check.
Separate queue delay from execution but report both when describing what a
person waited for. Jobs run concurrently; do not sum their elapsed durations.

The consumer graph is thirteen jobs: four Rails shards at four workers, five
serial E2E shards, the full component suite, frontend, Python, and an
aggregate result. On a public repository the runner pool is the only cost of
a shard; one complete run plus a deployment fits within twenty slots, absent
other account workflows. This is headroom, not a reserved deployment slot or
a guarantee against queueing. Measured on eight green `master` runs before the
split (October 2026): wall time 8.2–10.7 min with about 2 s of queueing, set
by Rails shard 2 of 2 (456 s of tests against 228 s on shard 1, the split
then being by byte size) and E2E shard 2 of 3 (389 s against 253 and 279).

Do not silently drop suites or retries to meet the two-minute target. Check
executed test counts against the source revision's discovery, not just a
historical number. If a long file sets the tail, inspect its duration before
changing parallelism or splitting it. Asset reuse must be tied to all relevant
build inputs; a generic "skip build" flag risks serving stale code.

Container jobs connect to the service hostname `postgres`, not host loopback.
The instance guard permits that exact alias only for `test` with both GitHub
Actions and CI markers set to `true`. Development, arbitrary remote hosts,
PGSERVICE and database URL overrides remain rejected; checkout claims and
runner locks are unchanged.
They use `--ipc=host` for Chromium. Browser tests run in an ephemeral root
container using Playwright's normal sandbox-disabled launch, with no production
or provider credentials; this is not a production-browser security policy.
