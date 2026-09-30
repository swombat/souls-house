# Frontend component boundaries

Rails/Inertia route pages stay pages: they compose sections, receive server
props, navigate and submit forms. Svelte components own coherent presentation
and local interaction. A section need not be reused elsewhere to deserve a name.

## Size policy

Count physical lines, including script, markup, CSS, comments and blank lines.
Formatting is for readability; compressing markup to satisfy a number is not a
refactor.

| File role | Review above | Ceiling |
| --- | ---: | ---: |
| Application component | 200 | 300 |
| Layout | 200 | 300 |
| Route page | 300 | 500 |

Most components should be roughly 50–150 lines with one clear responsibility.
The review threshold asks whether a meaningful boundary has appeared, rather
than requiring a component for every paragraph. New work must not exceed the
ceiling. An exceptional case needs a documented reason and explicit review, not
an unrecorded exemption. Content-heavy pages may justify being above the review
threshold; 900-line files are not the default even for pages.

`bun run check:svelte-size` warns at the review threshold and fails above the
ceiling. CI runs it. It covers `app/frontend` application Svelte files, excluding
shadcn primitives (upstream-style wrappers) and test mocks/harnesses. Those remain
reviewable on their own merits. Role matters more than directory:
`pages/chats/ChatList.svelte` is a component.

Apply the same judgment to extracted JavaScript: do not move a giant page into
a giant helper or introduce an application-wide store merely to reduce the
page's line count. Prefer small domain-specific modules and existing helpers.

## Current ownership

- Resident creation keeps one form, draft and final submission on the page;
  `agents/birth/` components render individual steps.
- Resident editing keeps the edit form and tab selection on the page. The hosting
  panel owns diagnostics, with separate runtime actions and filesystem views.
  It is loaded lazily and retained across tab switches, including preview state.
- Provider subscription state belongs to a per-panel reactive module; the
  connection dialog and usage display share that owner, not competing copies.
- Personal services separate connection input, per-connection Google authority
  drafts and resident provisioning controls. Personal and account-managed
  permissions must remain distinct.
- Chat history reconciles Inertia's recent window with older pages in one
  per-page owner. Runtime activity owns its refresh lifecycle; response state
  owns waiting/timeout feedback; mutations and dialogs have a separate owner.
  Timers/listeners/requests need cleanup on navigation or unmount.
- The chat page no longer listens for legacy token/thinking chunks. Current
  resident messages arrive as persisted API posts followed by normal prop
  invalidation. Runtime-activity polling and a fallback message refresh are not
  token streaming. Historical message fields/rendering and the legacy Rails
  stream concern are not removed by this UI refactor.
- `charts/activity-bars.svelte` is the shared renderer for memory, account usage,
  resident cards and runtime activity. It supports daily stacks and grouped sub-day buckets on
  one scale. Domain labels, legends and exact-count tables stay with their caller;
  a zero bar remains zero.
- Admin report sections preserve UTC/unknown-value semantics and use named
  formatters; memory history owns its filter/cursor/request lifecycle.

## Refactoring checks

Preserve server contracts, authorization and one owner for each mutable state.
Check same-record live updates versus switching records, unsaved drafts,
in-flight requests, tab revisits, errors/retries, subscription cancellation,
pagination seams and scroll position. Moving an element can affect scoped CSS,
form submission and accessibility even when its markup is unchanged.

Use existing behaviour tests as anchors. Add focused lifecycle/transform tests
where they protect a real regression, and run browser journeys for changes to
chat, resident forms, navigation or layout. See [testing](testing.md).
