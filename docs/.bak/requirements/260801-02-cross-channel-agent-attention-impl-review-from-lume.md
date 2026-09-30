# Implementation review: cross-channel agent attention — from Lume

**Date:** 2026-08-01
**Reviewing:** uncommitted implementation of `260801-02-cross-channel-agent-attention.md`
(`agent_attention_feed.rb`, `agent_attention_renderer.rb`, `attentions_controller.rb`, wake-request integration, docs)
**Verified:** all 19 tests in the four touched test files pass; rubocop clean on the three new files; `Chat::Archivable` supplies `kept`/`active`, `TelegramNotifiable` supplies `agent.telegram_subscriptions` — the scopes the feed leans on all exist.
**Verdict:** Approve, with one small fix requested (email fallback in Telegram items) and one missing spec-required test.

---

## What the implementation got right — including beyond the spec

Every substantive point from my spec review was adopted, and adopted well:

- **Per-channel `checked` status.** The feed rescues each channel independently, so a Telegram failure no longer discards retrievable HelixKit facts. The renderer's `partial_body` renders "HelixKit conversations were checked … Telegram status is unavailable; do not infer that Telegram is quiet" — §3.3's three-state honesty, now per channel. Both partial-failure directions are tested with stubs.
- **Author-split counts.** `counts.by_author_type` in the API, and the wake copy speaks in "2 threads currently end with a human message and 1 thread currently ends with another resident's message." This is the change that protects the human-latest signal against the resident-chatter floor.
- **The silence debt is named out loud, twice.** `public/ai/api.md`: "An item can remain after the agent has deliberately chosen silence because v1 has no acknowledgement mechanism." Runtime manual: "a thread you deliberately hold in silence can remain listed." The v1 cost is a documented fact residents can read, not a surprise they discover.
- **Preview redaction tested as a property.** The feed test creates a message with `thinking: "SECRET THINKING"` and `tools_used: ["SECRET TOOL"]` and asserts neither appears in the preview — exactly the regression pin I asked for.
- **Notices vs attention distinguished in the runtime docs** ("told to you" vs "checked for you"), and the manual even ships a `jq` recipe for pulling human-latest items without printing resident-latest threads into model context. That last touch is genuinely thoughtful — it hands residents a policy tool without the platform imposing policy.
- **Spec semantics all present and tested:** legacy agent-less assistant rows → `unknown` authorship, included; tool/system rows invisible as last speaker; archived/discarded excluded; blocked Telegram `reachable: false` with a two-year-old message still visible; agent isolation both channels; attachment placeholder; `DISTINCT ON` latest-per-thread with no N+1; wake integration in the scheduled-wake builder only.

## Requested fix

**Telegram `title`/`author_name` can leak a full email address.**
`TelegramSubscription#subscriber_name` falls back to `user.email_address` — the whole address. A subscriber whose profile has no full name yields `"title": "daniel@tenner.org"` in the feed. Spec §4.3 names email addresses explicitly among the things the payload must not include, and the HelixKit path in this same service already handles the identical fallback correctly (`email_address.split("@").first`). The two code paths disagree; the Telegram one is the non-conforming one.

Fix in the feed (don't change `subscriber_name` itself — other callers may rely on it): apply the same local-part fallback when building the Telegram item's `title` and `author_name`. One test: subscriber with no profile name → title contains no `@`.

Severity: minor in practice (agent-scoped key; the agent can see its own subscribers elsewhere) but it is a stated spec requirement and a two-line fix.

## Missing test

Spec §8 asks: "Ordinary conversation and Telegram request builders do not receive the cross-room section in v1." The builders are correctly untouched — the diff modifies only `external_agent_wake_request.rb` — but the spec wanted the pin, and it's the pin that stops a well-meaning future change from injecting the section everywhere the way notices are. Two `assert_not_includes text, "Cross-room attention"` assertions in the existing response/telegram builder tests would do it.

## Notes, no action required

- **`partial_body` assumes exactly two channels** — `checked.find { ok }` / `find { failed }` each name one channel. Correct for v1's frozen `CHANNELS`; a third channel would silently drop one from the copy. §3.2 says new channels must extend this feed, so a one-line comment ("assumes two channels; generalize when adding a third") would cheaply protect the invariant.
- **`sort_by!` block deletes `:sort_at` mid-sort.** Works — `sort_by` evaluates its key block exactly once per element — but it's a trap for a future editor who converts to `sort!` or re-runs the block. Consider deleting the key after sorting instead.
- **Renderer's outer `rescue` is untested.** The per-channel rescue makes feed-level raising nearly unreachable, and the all-failed state is tested, so this is the least important gap; noted only because the spec's test list named it.
- **Descending tie-breaker.** Ascending sort + `reverse!` makes the channel/thread-id tie-breaker descending rather than ascending. Deterministic and stable, which is all §4.2 requires. Fine.
- **Both-channels-failed returns HTTP 200** with `checked` all-failed and empty items. Right call — the request succeeded, the checks didn't — and api.md tells consumers to read `checked` before treating empty as quiet.

## Deployment note (carried over from the spec review)

Before first deploy, count legacy agent-less assistant rows that are the latest relevant message in an active chat. Every one becomes a permanent `unknown`-authored candidate clearable only by posting into a finished thread. If the number is large, the feed boots noisy and habituation starts on day one; a backfill of `agent_id` on single-agent conversations is safe and worth doing first.

---

*The spec review asked for three things by name — say the silence-cost out loud, split the counts, test the redaction — and all three are in the diff, plus the per-channel `checked` I marked optional. Fix the email fallback, add the negative builder test, and this is ready to commit.*
