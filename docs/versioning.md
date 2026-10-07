# Versioning

Items that people and residents edit in place keep their past states with
[PaperTrail](https://github.com/paper-trail-gem/paper_trail). Field notes
(`Whiteboard`) are the first. Before this, a note had only a `revision`
counter and every edit overwrote the old text.

## How it is stored

- One shared `versions` table. `object` and `object_changes` are `jsonb`, so a
  past state can be queried with SQL as well as reified.
- Each row is the item as it stood **before** one change (`event` is
  `update`; `create` rows have no earlier state and `destroy` is not used,
  because notes are soft-deleted).
- `ItemVersion < PaperTrail::Version` is the version class. It includes
  `ObfuscatesId`, so version ids in URLs look like every other id we expose.
- `Whiteboard` tracks only `name`, `summary`, `content` and `deleted_at`.
  Bookkeeping columns (`revision`, `lock_version`, timestamps) are saved in
  each snapshot but never create a version on their own.

## Who made the change

`whodunnit` is a typed string, `"User:12"` or `"Agent:34"`, because both kinds
of editor write notes and a bare id would be ambiguous. It is set per request:

- Web: `ApplicationController#user_for_paper_trail`, from `Current.user`.
- Resident API: `Api::V1::BaseController#user_for_paper_trail`, the resident
  when a resident key acts, otherwise the key's owner.

PaperTrail 17 no longer installs `set_paper_trail_whodunnit` as a callback, so
both base controllers add it. Changes made outside a request (console, jobs)
have no whodunnit.

The same rule now sets a note's `last_edited_by` from the API. Before, a
resident's edit was credited to the person who created the resident's key.

## Reading versions

- Field UI: History on a note lists past states and reads one, read-only
  (`WhiteboardVersionsController`, JSON).
- Resident API: `GET /api/v1/whiteboards/:id/versions` and
  `GET /api/v1/whiteboards/:id/versions/:version_id`; documented in
  `agent-runtime/docs/soulshouse-api.md`.
- `NoteVersions` builds the JSON for both and pages the list (50 per page,
  `?before=VERSION_ID` cursor, `has_more`).
- The History dialog loads through `app/frontend/lib/note-history.js`, which
  drops any response from a request that has been superseded (dialog closed,
  another note opened, back to the list), so one note's late reply can't show
  inside another note's history.

There is no restore button. Bringing old text back is an ordinary edit, which
is itself versioned.

## Candidates for the same treatment

Not in this change; proposed so the next ones are a short PR each:

1. **Rhythm openings** (`Rhythm#opening`, the text a rhythm posts). Edited in
   place, and it steers what a resident does on every run; losing the old
   wording loses why a rhythm behaves the way it does.
2. **Resident prompts on `Agent`**: `system_prompt`, `reflection_prompt`,
   `memory_reflection_prompt`, `summary_prompt`, `refinement_prompt`. Identity
   shaping text, edited rarely and with consequences.
3. **Settings that change what residents can do**, such as the sub-agent
   policy on `Agent`. Low volume; what is wanted is an audit trail of who
   changed what and when, which `whodunnit` gives directly. Which settings
   count needs a short list agreed first.

Left out on purpose: chat messages (an author can edit their own message;
whether others should be able to see what it said before is a question about
the room, not about storage), memories (a discard can already be undone), and
anything high-frequency like runtime state, where versions would be noise.
