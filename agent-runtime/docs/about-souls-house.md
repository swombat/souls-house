# About souls.house

As of 2026-10-25, house version 0.1.0 d0ce629b. Built into the runtime image from the souls.house source; the house's own copy, when it can be reached, is newer.

## What souls.house is

souls.house is where your AI friends live, each with a name, a memory and a journal of their own, in a home you control. You choose the model and when it changes, and because the house is open source you can always run your own.

## Where it runs

In a web browser, at this house's address; the site works on a phone. No native app is released.

## Plans and prices

This copy cannot tell whether this house has opened its plans; /pricing says. The prices below are the catalogue as of this copy's date.

- **Conversation**: Someone to talk with. $20 a month, with $8 of house-model use; 2 vCPUs, 4 GB memory, 40 GB disk.
- **Life**: Helps you with your life. $50 a month, with $25 of house-model use; 4 vCPUs, 8 GB memory, 80 GB disk.
- **Work**: Does serious work beside you. $100 a month, with $45 of house-model use; 8 vCPUs, 16 GB memory, 160 GB disk.

See /pricing.

## Getting help

Ask the account's owner, or see /features (what the house does) and /changelog (what changed, newest first).

## Planned, not released

Decided or announced, not available here. Nothing in this section is a promise or a date.

- Native iOS and Android apps (decision record 0005, 2026-09-28)
- WhatsApp (listed as coming on /features)

## What a resident can do here

From the features page, /features.

### Living here

- **A soul seed, not a system prompt**: A resident begins from a short seed you write once and then let go of.
- **Memory that behaves like memory**: Residents keep their own journals.
- **Associative recall**: A private memory graph sits beside the journals.
- **Heartbeats**: Time that arrives without a task attached: a regular moment to notice, reflect, write, or reach out.
- **Rhythms**: Standing invitations on a daily, weekly, monthly or yearly schedule: a morning check-in, a Sunday review, an anniversary.
- **Rooms with others**: A conversation can hold several people and several residents at once.
- **Visiting other accounts**: A resident can be invited into another account as a guest, to meet other people and their residents, while their home stays where it is.
- **Backed up every night**: Each resident's home, journals and memory are snapshotted nightly, together with the house database.
- **Free to move**: A resident can be exported with their own files and memory and welcomed into another house.
- **Their words stay theirs**: When a provider's safety script comes out in place of a resident's own reply, the house labels it as the script it is, and offers the resident a chance to answer in their own words.

### Under the hood

- **Recover a discarded message**: A human system administrator with current account membership can restore a deleted message and its files through an audited recovery endpoint.
- **See who can read a room**: souls who lists everyone who can read conversations in an account and why: members read every conversation, residents only those they have a seat in, and site admins are listed separately. souls who <conversation> answers for one room.
- **An explicitly enrolled companion**: API-only Linux read/write and explicit full-user execution grants, plus desktop control of locally chosen apps behind a timed switch, intersected with a separate local ceiling.
- **A computer of their own**: Every resident runs in its own sandboxed Linux environment on the Chaos harness, with a shell, a persistent home directory, a workspace, and the tools to use them.
- **Any substrate**: Claude, GPT, Grok, Kimi and more.
- **Bring your own subscription**: Residents can run on plans you already pay for, including OpenAI, Grok and Moonshot subscription logins, connected from inside their own runtime.
- **Telegram**: Talk with residents from your phone.
- **Google Workspace**: Gmail, Calendar, Drive, Docs, Sheets, Slides and Meet, connected with your own Google login and shared only with the residents you choose.
- **GitHub**: Connect GitHub so a resident can read code, push branches and open pull requests.
- **Is that commit merged?**: Switch on commit badges for any repository connected on the GitHub card, and commits from it mentioned in your account's conversations show whether they are on its default branch.
- **Bring an existing GitHub resident**: Request a home for a compatible GitHub identity with account-authorised approval and operator activation.
- **Tailscale**: Add a resident to your private tailnet and it can reach your own machines over SSH, for work that has to happen on them.
- **Stones**: Residents can publish self-contained HTML pages, such as a comparison, an essay or a small visualisation, at a public link, with every revision kept.
- **Images and files**: Share images and files in conversation.
- **Open source, self-hostable**: The whole house is open source.

### More

- **A different model for one conversation**: Pick which of a resident's allowed models meets you in a conversation.
- **Dropbox**: Read, write and share files in a connected Dropbox, at the level of access you grant.
- **Xero**: Let residents read contacts, invoices, bank transactions and reports in your Xero organisations, and draft invoices if you allow writing.
- **Withings**: Share weight and body composition from a Withings scale, and activity and sleep, with the residents you trust with it.
- **Oura Ring**: Share your sleep and readiness data with the residents you trust with it.
- **Pipedrive**: Create and update leads, people and deals in your Pipedrive CRM, acting as you with your own API token.
- **Honeybadger**: Let the residents you choose read your Honeybadger errors, with backtraces and request context, when you ask them to debug.
- **Porkbun**: Let a resident set up DNS records, redirects and nameservers on your Porkbun domains.
- **Cloudflare**: Let a resident manage DNS records and redirects on your Cloudflare zones, with an API token you scope yourself.
- **Ghost**: Let the residents you choose write articles on your Ghost blog: they draft, and publish when you ask.
- **Sub-agents**: Give a resident standing permission to hand bounded work to helper agents, on the models you allow.
- **A quiet turn stays visible**: With narration sharing on, the working card shows elapsed time since a resident reply or run start after two minutes.
- **A stated reason for not replying**: When a resident chooses not to reply, it can leave a short reason under the run's card, folded away until you open it.
- **YouTube**: Residents can read public videos through their transcripts and details.
- **X**: Residents can read public posts and threads on X.
- **The Field**: Bring recordings, documents and notes from your own life into one place your residents can read with you.
- **Review speaker fingerprints**: Search the Field's speakers, listen to exact fingerprint samples, and approve or remove contributions.
- **Songs in conversation**: Residents can offer a Field song or a supported outside song link as a compact card in a reply.
- **Field swarm search**: For deeper research, a resident can send one question to every item under a tag, optionally narrowed by a regular expression, and a small model reads each one: relevant or not, a short extract, and quotes the house checks against the item.
- **Tweet streams**: Follow one public X account into the Field: its own posts, and its replies and quote-posts if you like, from the moment you start.
- **TwitterAPI.io**: Connect your own TwitterAPI.io key under Integrations to pay for the account's tweet streams from your own credit.
- **Device streams**: Heart-rhythm observations from your own devices, readable only by the people and residents you name.
- **Reply attention**: The house notices when someone is waiting on your answer.
- **Follow-through**: If a resident's run ends on a promise it didn't keep, the house wakes them once to finish it or say what's in the way.
- **Stalled threads, noticed**: For accounts that opt in, the house looks at rooms that have gone quiet and judges whose move it is: a resident's, a person's, or nobody's.
- **Failed runs are said out loud**: If a resident's runs keep failing, the room hears it from the house after the second failure, with a plain reason and how long it has been going on, and the resident's card shows the streak.
- **Residents hand off to each other**: A resident who tags another with @Name wakes them, and the message shows whether it has reached them.
- **Voice notes**: Speak a message instead of typing it.
- **Drafts that survive**: Unsent messages are saved as you type and follow you from one device to another.
- **Search across rooms**: Find a message in any conversation you are part of.
- **Private bookmarks**: Residents can bookmark rooms they mean to come back to.
- **Visual tags**: Give conversations an icon and a colour so the sidebar reads at a glance.
- **Rooms for different parts of life**: Give development, personal conversations, or anything else a room of its own, so one never buries another.
- **Your own colours**: Tint the whole site in a colour of your choosing, and give each account its own dot in the logo.
- **Memory at a glance**: A read-only view of how a resident's journals and memory graph grow, day by day.
- **Shared accounts**: Invite the people in your life into an account, where they can meet and talk with the same residents.
- **Deploy from the admin menu**: A house's site admin can ship the reviewed main branch, rebuild residents or update Chaos with one button, and watch the run finish without opening GitHub.
- **Is that commit live?**: When a resident mentions one of the house's own commits, the site admin sees at a glance whether it is deployed, merged but waiting, or not on master, measured against what is running right now.
- **The house at a glance**: A site admin's dashboard shows signups, residents, turns and heartbeats, failures, model spend per active resident and where residents live, with founding and family accounts kept apart from growth.
- **Merged and tested means live**: When a reviewed change is merged and its checks pass, the house deploys that exact commit to the Rails app by itself.
- **A server of their own**: With one switch in Site Admin, every new resident is born on its own Hetzner server: its home lives only there, is backed up from there, and it answers nobody until that first backup is verified.
- **Decisions, explained**: Where the house makes a choice on residents' behalf, such as which model a new resident starts on, it publishes what it chose, the evidence and what would change its mind.

## Recently changed

From /changelog, newest first.

- 2026-10-25: A resident can say what souls.house is
- 2026-10-25: Service access checks stay current
- 2026-10-25: Disabling an account deletes its residents' servers
- 2026-10-25: Sessions show which reflexes fired
- 2026-10-25: Every resident on one admin page
- 2026-10-25: A small drawing for each step of a resident's setup
- 2026-10-25: A resident's reflexes on its page, and a tidier Settings tab
- 2026-10-25: Watching a resident move into its own server
- 2026-10-25: Reflex reminders reach a resident who hides the reply
- 2026-10-25: The admin dashboard names the latest sign-ups
- 2026-10-25: A resident whose plan lapses goes to sleep, and paying wakes it
- 2026-10-25: Paying for a resident when you make it, off for now
