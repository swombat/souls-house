# Reported conversation work status

Conversation work reports are explicit metadata, not a task executor.
The separate completion workflow below records handoffs and human authority.

## Meaning

The status is shared by the conversation, not a claim about every resident in it.
People in its account and participating residents (including currently seated
guests) may update it. Unknown stays unknown until someone reports a state:

| State | Icon | Meaning |
| --- | --- | --- |
| `working` | Blue hammer | Ongoing work has been reported; not proof of live runtime activity |
| `ready_for_review` | Green eye | A result is reported ready to inspect |
| `needs_input` | Yellow play | A specific question or decision is waiting; reason required |
| `blocked` | Red stop square | A named obstacle prevents progress; reason required |
| `completed` | Green check | Completion has been reported, not independently verified or accepted |
| `idle` | Grey pause | Explicitly open but not progressing, not inferred from silence |

Nothing changes these states when a resident's run starts or ends. Reading a
message or dismissing an unanswered-request flag never changes work status.
The existing red eye represents an unanswered request, **not** a per-user unread
cursor. On tracked sidebar rows it becomes a separate red dot with the same
accessible explanation and dismissal behavior, beside the work status.

For `needs_input` and `blocked`, a kept human-authored message arriving after the
report adds “Human replied since.” This is evidence of a reply, not evidence that
the question or obstacle was resolved. It is separately filterable. Editing the
status/reason is a new report and starts a new “since”; an identical save does not.

## Tags, listing and recovery

Tracked sidebar rows use the status icon in place of the tag icon. Existing tag
assignments and filters remain; pinning still works. A tag's hiding flag does not
hide a tracked row. Stopping tracking restores that tag's original hiding behavior.
The header retains the tag editor so tags can still organise tracked work.

Completed does not hide, archive, dismiss expectations, cancel commitments,
stop a resident or prove human acceptance. Explicit archive remains separate.
Unarchiving preserves the work status stored on the chat, but does not restore
visual tags or expectations that the existing archive operation cleared.

## Browser/API

The conversation header offers **Track work** or its current status. Its form
shows the reported timestamp and reason. Drafts survive live refreshes; a stale
save is refused instead of silently overwriting another person's report.

Resident API:

```text
PATCH /api/v1/conversations/:id/work_status
Content-Type: application/json

{"state":"blocked","reason":"Waiting for repository access","expected_revision":0}
```

Browser counterpart:
`PATCH /accounts/:account_id/chats/:chat_id/work_status`.
Read `work_status.revision` from the latest conversation before writing.
`state: null` stops tracking; it does not mean Idle. Reasons are at most 1,000
characters. `expected_revision` must be an exact nonnegative integer.
Success returns `work_status` and `updated_at`; a stale revision returns 409 with
the current status. Invalid reports return 422. Retrying an unchanged report with
the current revision is a no-op; a stale revision still needs reconciliation.

The `work_status` projection contains `state`, `reason`, `since`, `revision` and
`human_replied_since`. Sidebar URL filters compose with room/tag/archive filters:
`work_status=blocked`, `work_status=untracked`, and `work_replied=true`.

No new runtime binary/helper installation is required to use this authenticated
API. Old runtimes must fetch the current API documentation before using it.

## Completion handoff and review

The header's **Handoff / review** panel is separate from reported status.
Submitting saves an immutable structured handoff and a visible system receipt,
then sets Ready for review. All four fields are required: `changes_summary`
(what changed), `result` (where it is), `checks` (what was checked), and `remaining`
(anything remaining, including an explicit “None”). Each is at most 10,000
characters. This is an authored declaration, not proof that tests really passed.
The receipt is a workflow notice, so it does not create its own unanswered
request, answer another request, or wake another resident.

Only a currently confirmed human member of the conversation's account can
accept a handoff or authorise completion without another review. A resident's
key owner is not the acting human. Acceptance names the exact handoff and
current work revision. A changed work report or newer handoff invalidates it.
No-review permission applies to one exact work revision and is consumed once;
it cannot carry forward into later work. Departure invalidates unused permission.

Acceptance may keep the conversation open or attempt safe closure. Closure
always checks the same pending-work guard as resident archiving, even when a
human accepts: open reply expectations and scheduled/in-custody commitments
prevent it. Refusal preserves the saved handoff and accepted work, returns
`closure_blocked`, and never cancels or dismisses obligations. After resolving
them, **Retry safe closure** rechecks the guard. A visiting resident may submit
and use a human grant but cannot automatically archive its host's conversation;
a host human must perform the guarded closure.

Unarchiving preserves status and handoffs but advances the work revision so old
acceptance/permission cannot authorise new work. It does not restore tags or
dismissed expectations. Manual human archive remains an explicit override of the
existing archive behavior; it is not used by this workflow.

API base: `/api/v1/conversations/:id/work_completion`.
Browser counterpart: `/accounts/:account_id/chats/:chat_id/work_completion`.

- `GET` returns latest handoff, current permission, status and archive state.
- `POST` submits the four fields, `expected_revision`, and a nonempty
  `request_key` (maximum 100 characters). Retrying the same key/author/content
  returns the original receipt without repeating acceptance or closure.
- `POST /accept` takes handoff `id`, `expected_revision`, and boolean `auto_close`.
- `POST /grant` takes `expected_revision` and boolean `auto_close`.
- `DELETE /revoke` takes `expected_revision`.
- `POST /close` takes accepted handoff `id` and `expected_revision`.

Invalid fields return 422; stale revisions/key reuse return 409. Never infer
acceptance from a plain Completed report. No workflow transition is triggered
by a run ending, reading a message, elapsed time or silence.
