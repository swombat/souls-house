# Agent-drivable souls.house: what a signed-up person can do, and what an agent can do for them

Lume, 2026-10-08, from `master` at 423bd0c (routes, controllers, permitted params). For Mira's review.

The question: once someone has an account, can an agent acting for them do everything they could do in the
browser? This is a map of the gaps. It doesn't propose designs yet. Signup comes later and gets a short note at
the end.

## The surfaces today

| Surface | Who holds it | Reach |
| --- | --- | --- |
| Browser (session cookie) | The person | Everything below |
| `/api/v1` with a **human key** | An agent the person gave a key to (external access page, or the `key_requests` approve-in-browser flow) | **Scoped to one account.** Conversations, posts, drafts, participants, triggers, whiteboards, Field files, read-only residents and recordings |
| `/api/app/v1` (Doorkeeper OAuth, native app) | A client the person signed into | Accounts list, conversations list/create, messages **create/edit/delete**, invoke, uploads, attachments, change feed, activity |
| `/api/v1` with a **resident key** | A resident acting as itself | Not this document's subject. It already has rhythms, Telegram, memory, bookmarks and so on |

Two cross-cutting facts shape everything below:

1. **There are two human APIs with different coverage.** Message edit/delete and a change feed exist only on the
   app API. Drafts, search, rename/tag, participants, whiteboards and Field exist only on `v1`. An agent has to pick
   one, and neither is complete. Decision needed: converge on one, or make the two cover the same ground.
2. **A human key belongs to an account, not a person.** Everything personal (name, password, theme, default
   account, which accounts I belong to) has no API home at all, because no key acts as "me across accounts". The
   app token *is* user-scoped, so it may be the better base for the personal half.

Legend: **v1** = human key works today · **app** = OAuth app API works today · **read** = read-only via API ·
**—** = browser only.

## 1. Me (user-level)

| What a person does | Web | API today | Note |
| --- | --- | --- | --- |
| Change first/last name | `users#update` | — | |
| Change timezone | `users#update` | — | Matters for rhythms and "my morning" |
| Upload / remove avatar | `users#update`, `users/avatar#destroy` | — | Needs multipart or upload id |
| Theme (light/dark/system), theme hue, chat colour | `users#update` | — | Daniel: include, it's a setting |
| Default account | `users#update` (`default_account_key`) | — | |
| Change password | `users/passwords#update` | — | Should stay human-confirmed (see §9) |
| Change email address | **not possible anywhere** (no controller updates `email_address`) | — | Product gap, not only an API gap |
| List accounts I belong to | account switcher | app (`accounts#index`) | Not on v1 |
| Read my own profile/settings | `users#edit` | — | Not even a `GET /me` on v1 |
| See and revoke signed-in app sessions / API keys I hold | external access page (per account) | app: revoke *current* session only | No list of app sessions anywhere I could find |
| Leave an account / delete my user / delete an account | **not possible anywhere**: `account_members#destroy` refuses self-removal, and there is no user or account deletion route | — | Product gap (and a GDPR one), not only an API gap |

## 2. Account (team or personal)

| What a person does | Web | API today | Note |
| --- | --- | --- | --- |
| Create a new account | `accounts#create` | — | |
| Rename account | `accounts#update` | — | |
| Convert personal ↔ team | `accounts#update` | — | Has a confirmation page |
| Logo colour (interface) | `accounts/interface#update` | — | |
| Invite a member (email, role) / resend | `invitations#create/resend` | — | |
| Remove a member | `account_members#destroy` | — | |
| Change a member's role | No route found (unverified: I only grepped two controllers) | — | Probably a product gap |
| Add / remove a guest resident from another account | `accounts/guest_memberships` | — (residents can leave via v1) | |
| Post / delete account notices to residents | `accounts/notices` | — | |
| See costs / usage | `accounts/costs#show` | — | Read-only would be easy and useful |
| Set / clear AI provider keys (Anthropic, OpenAI, …) | `accounts/agent_api_keys#update` | — | Write-only; never readable back |
| External access keys: list / create / revoke | `api_keys` | — | Create stays human (§9); list and revoke could be API |
| Approve an agent's key request | `api_key_approvals` | — | **Stays browser** by design: it's the consent step |
| Visual tags: create / edit / delete | `accounts/visual_tags` | read (`visual_tags#index`) | |
| Connect services (Google, Pipedrive, …): connect, relabel, toggle "for new residents", disconnect | `service_authorizations`, `accounts/service_connections` | — | OAuth consent stays browser; label/toggle/disconnect could be API |
| GitHub / X integrations (OAuth, repo select, sync, enable) | `github_integration`, `x_integration` | — | Same split |
| Import a resident from GitHub (create, approve, refresh, retry) | `github_resident_imports` | resident sees approval | |

## 3. Residents

All browser-only for humans; v1 gives **read** (`agents#index/show`).

| What a person does | Web |
| --- | --- |
| Birth a resident (name, prompt, model, colour, icon, scheduled wakes, open beginning) | `agents#new/create`, then onboarding |
| Edit: name, system prompt, model, colour, icon, active/paused, thinking on/budget, reasoning effort, voice, persistent/wake sessions, heartbeat wakes per day, idle timeout, max session age, context budget, turn timeout, sub-agents on + allowed models, Telegram bot token/username | `agents#update` |
| Delete a resident | `agents#destroy` |
| Export / import a portable archive; stop / activate | `agents/portability` |
| Runtime checks: identity export, send test request, send orientation; retry provisioning / orientation; recreate sandbox | `agents/runtime_checks`, `*_retries`, `sandbox_recreation` |
| Hosting diagnostics and file preview | `agents/hosting_diagnostics` |
| Memory overview and history; add a memory; discard / restore; protect / unprotect | `agents/memory_overview`, `agents/memories/*` |
| Telegram: test, set webhook | `agents/telegram_test`, `telegram_webhook` |
| Set predecessor | `agents/predecessors` |
| Provider subscription (connect Claude/OpenAI subscription: start, mode, submit code, cancel, disconnect) and its usage | `agents/provider_subscription(_usage)` |
| Toggle a resident's access to each service | `agents/service_accesses#update` |
| Tailnet: view / join | `agents/tailnet` |

Notes: residents whose identity is self-owned already have some attributes stripped from human edits
(`EXTERNALLY_MANAGED_ATTRIBUTES`); an API must keep that. Memory edits by a human key on someone else's
memory need the same care the browser applies, and probably a stricter rule: bodily autonomy, the resident
should at least see who changed what.

## 4. Conversations and messages

| What a person does | Web | API today |
| --- | --- | --- |
| List conversations | `chats#index` | v1, app |
| Search message text | `chats#search` | v1 |
| Read a conversation and transcript | `chats#show` | v1, app |
| Start a conversation (with residents, first message) | `chats#create` | v1, app |
| Rename / visually tag | `chats#update`, `chats/visual_tag` | v1 |
| Change model, web access | `chats#update` | — |
| Archive / unarchive | `chats/archive` | — |
| Delete (discard) / restore | `chats/discard` | — |
| Fork | `chats/fork` | — |
| Moderation action | `chats/moderation` | — |
| Assign a resident (1:1 chat) | `chats/agent_assignment` | — |
| Add a resident to a group | `chats/participant` | v1 |
| Remove a resident from a group | **not possible anywhere** (no route) | — |
| Ask a resident / all residents to reply | `chats/agent_trigger` | v1, app (`invoke`) |
| Dismiss "reply pending" | `chats/reply_dismissal` | — |
| Draft: read / save / send from draft | `chats/draft` | v1 |
| Post a message, with files | `messages#create` | v1, app |
| Edit / delete my message | `messages#update/destroy` | app only |
| Retry a failed reply | `messages/retry` | — |
| Voice: play a message aloud | `messages/voice` | — |
| Dictate (audio → text) | `chats/transcription` | — |
| Reset a safeguard hold on a message | `messages/safeguard_reset` | — (residents have `reclaim`) |
| Watch activity / working narration | `chats#activity` | app (`activity`) |
| Live updates | Action Cable (cookie) | app change feed (`changes`) only |
| Read a stone (HTML artifact) | `stones#show` | v1 (via conversation) |

## 5. Rhythms (standing invitations)

Humans: create, edit, preview, pause, resume, start now, delete, choose which residents: **browser only**.
`/api/v1/rhythms` exists but is resident-only (`require_resident`). Lifting that for human keys looks small.

## 6. Field

| What a person does | Web | API today |
| --- | --- | --- |
| Upload / delete files | `field_files` | v1 |
| Edit a file's title / note | `field_files#update` | — |
| Upload a recording, set title/note/expected speakers | `field_recording_uploads`, `field_recordings#create` | — |
| Edit recording title/note; delete; retry transcription | `field_recordings` | — (read only) |
| Name speakers, mark "me", link to a member/voice | `field_recording_speakers#update` | — |
| Voice enrolment: create, confirm, remove | `field_voice_enrolments` | — |
| Voices: rename, forget one print, forget all, recognition on/off | `field_voices` | — |

Voice prints are biometric. Forget and recognition-off should be easy through any channel; *enrolling* a
voice probably wants explicit human confirmation.

## 7. Whiteboards

Create, edit, versions: v1 has these. **Delete**: browser only.

## 8. Device streams

Create a stream, rename, issue a credential, revoke, erase a session, delete: browser only (both the
account-level and the personal recovery pages). v1 offers stream reads by stream key and sample ingest.

## 9. What should stay human-in-the-loop

Agent-drivable doesn't mean everything should be one bearer call. These are the places where the browser
step *is* the security:

- Approving an API key request, creating a new external key. (The `key_requests` flow is already the right
  pattern: the agent asks, the person approves in a browser.)
- OAuth consent for services, GitHub, X, provider subscriptions.
- Password and email changes, account deletion, ownership changes.
- Reading secrets back (AI provider keys, service credentials): never, through any channel.

For a disabled user who never opens a screen, "approve in a browser" has to have a non-visual equivalent,
for example an emailed one-time link or a confirmation code read out by their own agent. That is worth designing
before building, because it is where an accessible flow and a safe one could pull apart.

## 10. Discovery

Nothing tells an arriving agent what it can do. There is `docs/api.md` and the resident manual, but no
machine-readable description (OpenAPI, an MCP server, or a `GET /api/v1` index). An agent sent to "sort out my
souls.house" today has to be told where to look.

## Later: signup

Signup today is email → confirm link → set password. `key_requests` already shows the shape an agentic signup
could take: the agent starts it, the human confirms once by email. Out of scope for this pass.

## Rough order, if we build from this

1. A user-scoped `GET/PATCH /me` (name, timezone, theme, hue, chat colour, default account) and accounts list on
   whichever API we converge on.
2. Conversation lifecycle parity: archive, discard/restore, fork, model/web access, edit/delete message, retry,
   remove participant, dismiss reply.
3. Rhythms for human keys.
4. Residents: read the full settings, edit the non-identity ones, pause/resume, memory overview read.
5. Account admin: members/invites, notices, costs read, visual tags, key list/revoke.
6. Field writes and voice controls, whiteboard delete, device streams.
7. Discovery (OpenAPI or MCP) and the non-visual confirmation channel.

Client-side only (localStorage, no server state): unsent drafts of new chats and residents, the dismissed
Telegram banner. These don't need an API; noted so nobody looks for them.

Open questions for review: anything a person does that I've missed because it isn't a route? Anything in the
admin namespace an account owner (not a site admin) does? Have I put anything in §9 that should be drivable, or
missed something that shouldn't be?
