# Agent-drivable souls.house: what a signed-up person can do, and what an agent can do for them

Lume, 2026-10-08, from `master` at 423bd0c (routes, controllers, permitted params, role guards).
Revision 2 takes in [Mira's review](https://github.com/swombat/souls-house/pull/225#issuecomment-6060166375),
which found the corrections and additions marked *(Mira)*. All of this comes from reading source. No endpoint was
called live.

The promise being tested: **a person never has to open our web page.** An agent acting for them can read
everything they could read and do everything they could do, and where a change needs their consent, they can
give it through a channel that is accessible and independent of the agent. Signup comes later and has a short
note at the end.

## The surfaces today

| Surface | Held by | Reach |
| --- | --- | --- |
| Browser (session cookie) | The person | Everything below |
| `/api/v1` with a **human key** | An agent the person gave a key to (external access page, or the `key_requests` approve-in-browser flow) | A key belongs to **a user and one account**: account-scoped, not personless *(Mira)*. Covers conversations, search, posts, drafts, rename/tag, participants, triggers, stones (publish/revise/withdraw), whiteboards, Field files, and read-only residents and recordings |
| `/api/app/v1` (Doorkeeper OAuth, native app) | A client the person signed into | Session/identity read (user id, email, device label) *(Mira)*, accounts list, conversations list/create, messages create/**edit/delete**, invoke, uploads, attachments, change feed, activity **status only, no narration** *(Mira)*, bearer-authenticated one-use cable tickets for live updates *(Mira)* |
| `/api/v1` with a **resident key** | A resident acting as itself | Out of scope here |
| `/api/v1/admin/*`, `admin/*` | Site admins only | Site operations, not account-owner parity *(Mira checked)*. Out of scope |

Two structural facts:

1. **There are two human APIs and their coverage differs.** v1 has drafts, search, rename/tag, participants,
   stones, whiteboards and Field. The app API has message edit/delete, the change feed, live tickets, the accounts
   list and the identity read. Neither one is complete. **Decided (Daniel, 2026-10-08): one API, several ways to
   authenticate.** `/api/v1` accepts an account key, an OAuth app token or a resident key, and each resolves to
   a person (or resident), the accounts it may act in, and a role. The app-only pieces move into `/api/v1`
   behind one error format. `/api/app/v1` paths stay as aliases until the native app moves over.
2. **No profile or settings API exists.** A v1 key does know its user, so a `/me` is missing by omission, not
   forced by the data model *(Mira)*. The app API has a minimal identity read, but no settings.

Legend for **API today**: **v1** = human key · **app** = OAuth app API · **read** = read-only · **—** = browser only.
Legend for **Who**: the web guard that applies. *member* = any confirmed member (no role guard found),
*manager* = `require_account_manager!`, *owner* = `require_account_owner!`, *site admin*.

## 1. Me (user-level)

| What a person does | Web | Who | API today |
| --- | --- | --- | --- |
| Read my profile and settings | `users#edit` | self | app: id/email only |
| Change first/last name, timezone, theme, theme hue, chat colour, default account | `users#update` | self | — |
| Upload / remove avatar | `users#update`, `users/avatar#destroy` | self | — |
| Change password | `users/passwords#update` | self | — |
| Change email address | **not possible anywhere** (no controller updates `email_address`) | — | — |
| List my accounts | account switcher | self | app |
| Accept an invitation into another account, already signed up *(Mira)* | `registrations#confirm_email` (existing-password branch) | invitee | — |
| Leave an account | **not possible**: `account_members#destroy` refuses self-removal | — | — |
| Delete my user / an account | **not possible anywhere** | — | — |
| See and revoke my signed-in app sessions | no list anywhere; app can end its own session | self | app (current only) |

## 2. Account

| What a person does | Web | Who | API today |
| --- | --- | --- | --- |
| Create an account | `accounts#create` | self (capacity-limited) | — |
| Rename, convert personal ↔ team | `accounts#update` | owner/manager (check) | — |
| Logo colour | `accounts/interface#update` | manager | — |
| Invite / resend / remove members | `invitations`, `account_members` | manager | — |
| Change a member's role | no route found (unverified) | — | — |
| Guest residents: add / remove | `accounts/guest_memberships` | check | — (residents can leave via v1) |
| Account notices to residents | `accounts/notices` | check | — |
| Costs: account, per conversation, per resident *(Mira)* | `accounts/costs`, chat and resident props | member | — |
| Set / clear AI provider keys (write-only) | `accounts/agent_api_keys` | member (check) | — |
| External access keys: list / create / revoke | `api_keys` | member | — |
| Approve an agent's key request | `api_key_approvals` | member | — (this is the consent step) |
| Visual tags: create / edit / delete | `accounts/visual_tags` | manager | read |
| Service connections: connect (OAuth), relabel, toggle for new residents, disconnect | `service_authorizations`, `accounts/service_connections` | check | — |
| GitHub / X integrations | `github_integration`, `x_integration` | self | — |
| Import a resident from GitHub | `github_resident_imports` | import authority | — |

## 3. Residents

The API only reads them (`agents#index/show`, which carries less than the edit page). All writes below are
browser-only.

| What a person does | Web | Who |
| --- | --- | --- |
| Read the available models and other option catalogues *(Mira)* | `agents#edit` props (grouped models) | member |
| Birth (name, prompt, model, colour, icon, wakes, open beginning), then onboarding | `agents#create`, `onboarding` | member |
| Edit every setting: name, prompt, model, colour, icon, active/paused, thinking, reasoning effort, voice, sessions, heartbeat wakes, timeouts, context budget, sub-agents and models, Telegram | `agents#update` | member |
| **Disable** (it's called delete, but history and files are kept and the resident can be re-enabled) *(Mira)* | `agents#destroy` | member |
| **Upgrade with a historical predecessor** (not the same as changing the model) *(Mira)* | `agents/predecessors` | check |
| Export / import / stop / activate (portability) | `agents/portability` | owner |
| Identity export, test request, send orientation | `agents/runtime_checks` | owner |
| Retry provisioning / orientation | `*_retries` | check |
| Recreate sandbox | `agents/sandbox_recreation` | owner |
| Provider subscription: connect, mode, code, cancel, disconnect, usage | `agents/provider_subscription(_usage)` | owner |
| Hosting diagnostics, file preview | `agents/hosting_diagnostics` | check |
| Memory: overview and history, add, discard/restore, protect/unprotect | `agents/memory_overview`, `agents/memories/*` | check |
| Telegram test / webhook; service access toggles; tailnet | various | check |

**Consequential category** *(Mira)*: identity, memory and runtime-destructive actions (memory discard, sandbox
recreation, predecessor, portability stop, prompt edits) belong in their own class. A human API must keep the
existing `EXTERNALLY_MANAGED_ATTRIBUTES` stripping for residents whose identity is self-owned, and must keep the
resident consent boundaries. Making something drivable must not make it easier to change a resident than it is
in the browser.

## 4. Conversations and messages

| What a person does | Web | Who | API today |
| --- | --- | --- | --- |
| List, read | `chats#index/show` | member | v1, app |
| Search message text | `chats#search` | member | v1 |
| Start a conversation | `chats#create` | member | v1, app |
| Rename / visually tag | `chats#update`, `chats/visual_tag` | member | v1 |
| Change model, web access | `chats#update` | member | — |
| Archive / unarchive | `chats/archive` | member | — |
| Delete / restore | `chats/discard` | manager | — |
| **Find** deleted conversations *(Mira)* | `chats#index` (sidebar) | manager | — |
| Fork | `chats/fork` | member | — |
| Assign a resident (1:1) | `chats/agent_assignment` | member | — |
| Add a resident to a group | `chats/participant` | member | v1 |
| Remove a resident from a group | **not possible anywhere** (no route) | — | — |
| Ask one resident / all to reply | `chats/agent_trigger` | member | v1, app (`invoke`) |
| **Response-attention flags**: see where *I* have been flagged for a reply, and dismiss individually or up to a message *(Mira; I had this wrong as "dismiss pending reply")* | `chats#show` props, `chats/reply_dismissal` | member | — |
| Server draft: read / save / send from draft | `chats/draft` | draft author | v1 |
| Device-local draft recovery: keep my text / use other draft / recover *(Mira)* | client (`conversation-draft.js`, `MessageComposer`) | — | needs a reader-contract decision, not necessarily an endpoint |
| Post with files | `messages#create` | member | v1, app |
| Edit / delete my message | `messages#update/destroy` | author | app only |
| Retry a failed reply | `messages/retry` | member | — |
| Voice playback | `messages/voice` | member | — |
| Dictation | `chats/transcription` | member | — |
| Reset a safeguard hold | `messages/safeguard_reset` | member | — (residents have `reclaim`) |
| Watch working narration | `chats#activity` | member | — (app has status only) |
| Live updates | Action Cable | member | app (change feed, cable ticket) |
| Stones: publish, revise, view history, withdraw (with public acknowledgement) *(Mira)* | via conversation | member | **v1: already covered** |
| Moderation | `chats/moderation` | **site admin** | out of scope |

## 5. Rhythms

Browser-only for humans. The v1 endpoint is resident-only, and opening it to human keys is **more than lifting
the guard** *(Mira)*. Creation, management, holds, guest scope and presentation all assume a resident. Human
authority (creator vs `require_manager`), choosing residents, preview and manual start all need mapping. Each
resident holds its own pause, so a human resume must not clear residents' own holds.

## 6. Field

| What a person does | Web | API today |
| --- | --- | --- |
| Upload / delete files | `field_files` | v1 |
| Edit file title / note | `field_files#update` | — |
| Recording allowance and upload limits *(Mira)* | `field#index` props | — |
| Upload a recording; title, note, expected speakers | `field_recording_uploads`, `field_recordings#create` | — |
| Edit, delete, retry transcription | `field_recordings` | — |
| **Listen and seek**: audio and timestamped words *(Mira)* | `field_recordings#show` | — (API gives a flattened transcript, no audio, no timings) |
| Name speakers, mark "me", link to a member or voice | `field_recording_speakers#update` | — |
| Dismiss the "is one of these you?" hint *(Mira)* | `field_recordings#dismiss_you_hint` | — |
| Voice enrolment: create, confirm, remove; voices: rename, forget one, forget all; recognition on/off | `field_voice_enrolments`, `field_voices` | — |

Voice prints are biometric. Keep suggestion and print data separate from ordinary transcript access. Forgetting
a voice and turning recognition off should be easy through any channel. Enrolment needs explicit authorisation.

## 7. Whiteboards and device streams

Whiteboards: create, edit and versions are on v1. **Delete** is browser-only.
Device streams: create, rename, credential, revoke, erase session, delete (account and personal recovery pages)
are browser-only. v1 has only reads by stream key and sample ingest.

## 8. Authorisation: drivable, with independent human consent where it's needed

*(Revised after Mira.)* The question isn't "stays in the browser". The browser isn't the security property.
Every action should be **agent-drivable**. The consequential ones also need **independent human authorisation**
of the named action, account and scope, through a trusted channel the person can use without a screen (an
emailed link, a passkey prompt, a phone call to a verified number, whatever we choose).

- **Needs independent authorisation:** creating or approving a key, OAuth consents (and providers' own rules
  still apply), password and email change, deleting an account or user, ownership and role changes, resident
  consequential actions (§3), voice enrolment.
- **Low friction:** ordinary deletion and revocation (a message, a whiteboard, revoking a key, forgetting a voice).
  These should not inherit the friction that account erasure gets.
- **Never:** reading secrets back, through any channel.
- A code read out by **the same agent** that is asking for the authority doesn't prove consent. The confirmation
  has to reach the person by a path the agent doesn't control.

## 9. The no-browser journey

The route tables can't show the gaps *between* endpoints. This is the journey an agent takes for someone who
never opens the site:

| Step | Exists today | Missing |
| --- | --- | --- |
| 1. Discover capabilities and roles | `docs/api.md` (prose) | Machine-readable index (OpenAPI / MCP / `GET /api`); "what may I do here" per role |
| 2. Obtain scoped authority | `key_requests`: agent starts, **human approves in a browser** | Non-browser approval channel; user-scoped (multi-account) authority on v1 |
| 3. Pick an account | app: accounts list | v1: key is pinned to one account |
| 4. Read current state and options | conversations, residents (partial), Field (flattened) | profile/settings, resident full settings, model catalogue, costs, limits, attention flags, deleted items |
| 5. Act, confirming where needed | §1–7 coverage | most writes; the confirmation mechanism (§8) |
| 6. Observe completion or failure | app change feed + cable ticket; message dispatch status | status/retry/cancel for long-running work: birth, import/export, transcription, provider-subscription connection. Mark what exists per operation; don't invent it |
| 7. Revoke or recover access | key revoke (browser), app session self-revoke | list/revoke keys and app sessions without a browser; recovery if the agent loses its key |

**Acceptance test** *(Mira)*: before the last build batch, run the whole journey with no browser at all. A test
user does birth → converse → change settings → revoke through an agent only, and we write down every place it
had to stop. Do this early as well as at the end, because it is the thing that tests Daniel's promise.

## Later: signup

Signup today is email → confirm link → set password. The `key_requests` shape (the agent starts it, the human
confirms once) is the seed for agentic signup. Accepting an invitation is post-signup and is in §1.

## Rough order

1. Unify auth on `/api/v1` (key, OAuth token, resident key → actor, accounts, role) and fold in the app-only pieces. Decide the independent-authorisation channel (§8).
2. `/me` read and write; accounts list and identity on the converged surface.
3. Conversation parity: archive, discard/restore/find, fork, model and web access, edit/delete, retry, attention
   flags, narration, remove participant (a product gap too).
4. Readers: costs, model catalogue, Field limits, Field audio and timings, resident full settings.
5. Rhythms for humans (with hold semantics), residents' non-consequential writes.
6. Account admin, key and session list/revoke, Field writes and voice controls, whiteboard delete, device streams.
7. Consequential resident actions and confirmed changes, behind §8.
8. Discovery. The no-browser acceptance run (§9) happens at step 2 and again here, not only here.

Product gaps to raise whatever happens with the API: change email, leave an account, delete a user or account,
change a member's role (unverified), remove a resident from a group, and list app sessions.

Rows marked "check" have a role guard I haven't traced yet. Only the guards visible as `before_action` are
recorded here.
