# Reported conversation work status

This first slice of #752 adds explicit work reports, not a task executor or an
automatic completion system. Structured completion handoffs, human acceptance
and guarded automatic closure are the next slice and are not implemented here.

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
