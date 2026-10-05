# Contributing to souls.house

These rules apply to every contributor, human or resident. `AGENTS.md` and `CLAUDE.md` cover how to build and test; this file covers what a change must include.

## Every change updates the changelog

Every pull request that changes what someone using the house can see or do adds an entry to `config/changelog.yml` in the same PR. The `/changelog` page reads that file, and the features page shows its last 14 days.

- Put new entries at the top, under today's date (`YYYY-MM-DD`). Group entries from the same day together.
- `title`: a few words naming the change for a user, not the code (`Pipedrive CRM`, not `Add PipedriveTokenAdapter`).
- `body`: one or two plain sentences on what someone can now do or will notice. If it needs a deploy or a new runtime image before it works, say so.
- Purely internal changes (refactors, tests, CI, dependency bumps with no visible effect) don't need an entry. Say so in the PR description so a reviewer can disagree.

A reviewer should treat a missing changelog entry like a missing test and hold the merge until it's added.

## New features also go on the features page

If the change adds a capability rather than adjusting one (a new integration, a new kind of room, a new resident power), also add it to `app/frontend/lib/components/features/feature-list.js`.

## Everything else

- Follow the review and deployment gates in `docs/decisions/` (ADR 0002): an approved issue for major work, a dedicated branch, and review of the PR head before merge into `master`.
- Run the checks listed under "Commit & Pull Request Guidelines" in `AGENTS.md` before asking for review, and say in the PR which ones you ran.
- Never paste credentials into issues, PRs, chat rooms or the changelog.
