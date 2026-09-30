# Continuous integration

[GitHub Actions](https://github.com/swombat/souls-house/actions/workflows/ci.yml)
runs on every pull request, every push to `master` (including merges), and manual
workflow dispatch. Standard Ubuntu runners are free for this public repository;
no larger runners, self-hosted machines, or deployment jobs are used.

The independent checks run the complete Rails and Rails system suites, frontend Vitest suite,
Playwright end-to-end suite, Playwright component suite, and Python runtime/build
contract suites. A failure in one suite does not cancel the others. Tests are not
filtered to changed paths and failures are not allowed to pass silently.

Each application job has a fresh PostgreSQL 17 service and isolated test instance.
Ruby comes from `.ruby-version`; Bun comes from `package.json`. Dependencies use
the committed lockfiles. `config/environments/test.rb` uses public, test-only
encryption keys; they must never be used for real data. Browser suites use the normal ownership-checked runners,
which build assets and start/stop their own Rails backend. Failed browser runs
retain reports, screenshots, traces and backend logs for seven days.

CI has read-only repository permissions and does not receive Rails master keys,
provider credentials, resident homes, deployment secrets or a production database.
Pull requests use `pull_request`, **not** `pull_request_target`, so fork code does
not run with privileged base-repository credentials. External API tests use the
committed VCR recordings; this is not a live-provider or deployment smoke test.
Optional real-Docker deployment/backup exercises are not part of this workflow.

Checks report on commits and PRs; they do not themselves require a green result
before merging. That is a separate repository branch-protection/ruleset policy.

## Local checks

Use the normal commands from an isolated checkout (see
[multi-instance development](multi-instance-development.md)):

```sh
RAILS_ENV=test bin/rails db:prepare
bin/rails test
bin/rails test:system
bun run test:unit --run
bun run test
bun run test:ct
python3 -m unittest discover -s test -p '*_test.py'
python3 -m unittest discover -s test/runtime -p '*_test.py'
```

Install libvips and FFmpeg as well as PostgreSQL and the pinned Ruby/Bun tools.
The media tests actually decode images and extract video frames. Browser tests
need `bunx playwright install --with-deps chromium` on Linux. Use a UTF-8 locale.
Run Rails and browser suites sequentially in a checkout so their test-database
ownership lock is respected. CI puts those suites on separate fresh machines.

The workflow is a test gate, not a formatter or security audit. The repository's
separate `bin/rubocop` and `bun run format:check` commands remain available.

### Component-test boundaries

The component suite mounts the current pages using synthetic serialized props.
Use `content` for Markdown messages, explicit `respondable`/`manual_responses`
chat state, server-provided model choices, and nullable profile fields such as
`chat_colour`. Shared Inertia page props must be set inside a browser-side
harness, not by changing a store in the Node test process.

The component Inertia adapter is not the full navigation client. Authentication
integration tests still use the owned Rails backend; UI-only submission tests
intercept specific endpoints to check payloads and pending/error recovery without
calling providers. The separate E2E suite checks real authenticated persistence.
Use accessible names or scoped test IDs rather than random placeholder text,
positional SVG/button selectors, or retired product names.
