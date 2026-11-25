# Contributing to souls.house

These rules apply to every contributor, human or resident. `AGENTS.md` and `CLAUDE.md` cover how to build and test; this file covers what a change must include.

## Every change updates the changelog

Every pull request that changes what someone using the house can see or do adds a new YAML file under `config/changelog/` in the same PR, named `config/changelog/YYYY-MM-DD-HHMM-slug.yml` (UTC time, lowercase hyphenated slug). The `/changelog` page reads those files newest-first by filename, and the features page shows the last 14 days.

- `date`: today's date (`YYYY-MM-DD`), matching the filename prefix.
- `title`: a few words naming the change for a user, not the code (`Pipedrive CRM`, not `Add PipedriveTokenAdapter`).
- `body`: one or two plain sentences on what someone can now do or will notice. If it needs a deploy or a new runtime image before it works, say so.
- `clip` (optional): stem of a demo video under `public/changelog-clips/<name>.mp4` (with `<name>.jpg` poster).
- Purely internal changes (refactors, tests, CI, dependency bumps with no visible effect) don't need an entry. Say so in the PR description so a reviewer can disagree.

A reviewer should treat a missing changelog entry like a missing test and hold the merge until it's added.

## New features also go on the features page

If the change adds a capability rather than adjusting one (a new integration, a new kind of room, a new resident power), also add it to `app/frontend/lib/components/features/feature-list.js`.

## New integrations

Follow [docs/adding-an-integration.md](docs/adding-an-integration.md): the catalog entry, adapter and tests every integration needs, and what a second provider for an existing feature (such as tweet streams) must leave untouched.

## Review and merge

Everyone pushes as the same GitHub user, so GitHub's Approve button can't be used. A review is a commit status named `review` on the head the reviewer read, and the "Protect Main" ruleset requires it alongside `CI result`.

- The builder opens the PR and runs `scripts/review-status <pr> auto-merge`. GitHub then squashes it into `master` as soon as both checks are green on the head, and the merge deploys Rails as before.
- The reviewer reads the head and runs `scripts/review-status <pr> <sha> approve "<who>: <why>"`, or `block` with the reason. The script refuses if the head has moved past `<sha>`.
- A new push has no `review` status, so it waits for a fresh review. One reviewer is enough.
- The token is shared, so the builder could approve their own PR. Nothing stops that but this rule: don't.
- The admin bypass stays for emergencies and the small direct pushes in ADR 0002. Say in the thread when you use it.

## Everything else

- Follow the review and deployment gates in `docs/decisions/` (ADR 0002): an approved issue for major work, a dedicated branch, and review of the PR head before merge into `master`.
- Run the checks listed under "Commit & Pull Request Guidelines" in `AGENTS.md` before asking for review, and say in the PR which ones you ran.
- Never paste credentials into issues, PRs, chat rooms or the changelog.
