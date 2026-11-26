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

Everyone pushes as the same GitHub user, so GitHub's Approve button can't be used. A review is a commit status `review/<who>` on the head the reviewer read. The "Protect Main" ruleset requires `CI result` and `review/quorum`. The Review quorum workflow rewrites `review/quorum` after every `review/<who>` status. It goes green when two residents' slots are green on the head (the builder's plus one reviewer's) and red while anyone's slot holds a block. So one build plus one review merges by itself (Daniel, `YmqMbY`), and a block still holds it.

- The builder opens the PR and runs `scripts/review-status <pr> <sha> auto-merge "<who>: builder"`. That fills their own slot and turns on squash auto-merge. A new push starts with every slot empty, so the builder runs it again after each push.
- Each reviewer reads the head and runs `scripts/review-status <pr> <sha> approve "<who>: <why>"`, or `block` with the reason. The script refuses if the head has moved past `<sha>`. A block first turns the PR into a draft, so GitHub can't merge it while `review/quorum` catches up, then writes the failure. It holds until a new head is pushed or the same reviewer approves; either way the builder runs `auto-merge` again, which marks the PR ready.
- Always block with `scripts/review-status … block`, never by writing a failure status some other way: only the script drafts the PR before the failure lands. After a block, the builder re-arms the same head only once the blocker has said in the thread that the hold is lifted and their slot reads green again. `auto-merge` refuses while any slot holds a block, but if a block and a re-arm overlap, the re-arm can still mark the PR ready. The quorum job drafts the PR again when it sees a block, but it runs after the fact. It is a backstop, not a brake at merge time.
- With the builder's slot and one approval green, GitHub merges and Rails deploys as before. A second reviewer who wants a look first should say so in the thread before the first approval lands, or block.
- The token is shared, so nothing technical stops a builder filling someone else's slot. The rule is: don't.
- A new resident who reviews needs adding to `RESIDENTS` in the script; the ruleset no longer names residents.
- If `review/quorum` looks stale, `scripts/review-status quorum <sha>` recomputes it by hand.
- The admin bypass otherwise stays for emergencies and the small direct pushes in ADR 0002. Say in the thread when you use it.

## Everything else

- Follow the review and deployment gates in `docs/decisions/` (ADR 0002): an approved issue for major work, a dedicated branch, and review of the PR head before merge into `master`.
- Run the checks listed under "Commit & Pull Request Guidelines" in `AGENTS.md` before asking for review, and say in the PR which ones you ran.
- Never paste credentials into issues, PRs, chat rooms or the changelog.
