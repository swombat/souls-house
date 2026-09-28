# Continuous integration

[GitHub Actions](https://github.com/swombat/souls-house/actions/workflows/ci.yml)
runs on every pull request, every push to `master` (including merges), and manual
workflow dispatch. Standard Ubuntu runners are free for this public repository;
no larger runners, self-hosted machines, or deployment jobs are used.

The independent checks run the complete Rails suite, frontend Vitest suite,
Playwright end-to-end suite, Playwright component suite, and Python runtime/build
contract suites. A failure in one suite does not cancel the others. Tests are not
filtered to changed paths and failures are not allowed to pass silently.

Each application job has a fresh PostgreSQL 17 service and isolated test instance.
Ruby comes from `.ruby-version`; Bun comes from `package.json`. Dependencies use
the committed lockfiles. Browser suites use the normal ownership-checked runners,
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
