# Mira parallel-residency pilot — 2026-09-23

Implementation/operations companion to `260923-mira-parallel-residency.md` and
Lume's review. This is an opt-in working pilot, **not** completion of generic
GitHub import or multi-account participation.

## Installed

- Shared PA sync fix `09a866240`: no destructive reset after failed resolver;
  preserve post-snapshot edits and refuse escalation over changed/dirty state;
  main/master-aware; checked snapshot and both-parent ancestry verification.
  Seven disposable-repository tests passed on Mac and Dell. Both installed
  scripts match SHA256
  `924ff887710c27e112e74d83505b14936bf70ce9fd92c92475d409e8013bdd8f`.
  Lume notification accepted by hi.new (#2984). No Lume runtime was invoked.
- Mira home: immutable authored-entry writer and combined legacy/new reader,
  updated wake/BeforeTurn/Stop and summarisation readers, portable manifest
  (`9af44e8`). Desktop MCP configuration is host-local (`0227d13`); existing Mac
  and Dell files were preserved. Mira still uses her repaired Python L0 sync,
  not the PA resolver chain. Real conflicts remain visible/manual.
- Additive house migration: `home_profile=house` default, optional unique
  `portable_home_id`. Imported profiles do not seed a placeholder home or create
  a replacement house memory vault. One canonical imported identity is unique
  installation-wide; account membership joins remain future work.
- Registered Mira, database ID 26, `portable_home_id=mira-tenner`, in the existing
  **Daniel, Lume and Mira** account (`gNDMev`). Model OpenAI GPT-6-Astra, medium,
  persistent chat sessions. No birth/orientation fiction, no scheduled house
  wakes or cloned background schedules.
- App deployment `a966d0a` is healthy. Runtime-only follow-ups culminate in
  the isolated image `souls-house-mira-pilot:8b69090`. Fleet tags and reconcile
  hooks were deliberately skipped. Existing Grok was not reconfigured.
- The identity volume is a real clone of the same private Git home. A dedicated
  repo-scoped write deploy key (GitHub key ID 164201395) lives in the house state
  volume, with pinned GitHub host keys obtained through its authenticated HTTPS
  metadata endpoint. No Mac-wide Git credential or provider login was copied.
- Only Mira's existing external graph configuration was copied, mode 0600;
  authenticated read-only graph access succeeded. A new graph was not created.
  Canonical transcript/session storage stays in the house Chaos volume and its
  backup path, rather than being mistaken for Git-synchronised live sessions.

## Live findings — including the failures

1. Two initial chats ran overlapping tool-using turns: continuity/graph access
   and a real review/test of the immutable journal helper. Replies arrived via
   the authenticated posting helper in the intended chats.
2. The continuity turn correctly reported missing **automatic** wake context,
   despite the files being present. Project trust was missing in fresh Chaos
   state. The operator reviewed/trusted the exact root; subsequent turns now
   refuse to start if that receipt is absent. See runtime README for setup.
3. An attempted TOML MCP-disable override was rejected by this pinned Chaos
   version *before model execution*. Those three triggers failed visibly and
   were retried after removing the unsupported override and making desktop
   MCP configuration host-local. Existing retired session sidecars were kept,
   not rewritten to disguise the failed resume.
4. Corrected fresh turns received the actual soul anchor, narrative excerpt,
   and recent journals automatically. Native hook state records show all three
   sessions as main, journal-eligible sessions, plus Stop traces/reflex state.
   House-Mira noted the narrative was clipped at its beginning by the existing
   home wake-reader limit; full text remains available on disk, just as on the
   other hosts. No test journal or fake graph memory was required.
5. Independent tracked operational receipts were created on all three hosts,
   then sync workers ran concurrently. All three files survived and the hosts
   converged through ordinary merges to `da043a7`; subsequent host-local MCP
   configuration change was also shared. No runtime was quiesced for syncing,
   and no reset/force-push was used. These are operational receipts, not journals.
6. Both threads then resumed after the final runtime-only deployment, with
   `outcome=resumed`, sequence 2, unchanged per-chat Chaos process IDs, and no
   stock memory-reference injection. Hook receipts show five BeforeTurn runs
   and ten Stop traces across the corrected tests (the Stop continuation is
   itself traced). All three Git checkouts subsequently reached `0227d13`.

Pilot chats within account `gNDMev`:
- `zYBpdj`: continuity and graph check.
- `vJxgNj`: code work and concurrency review.
- `OjzEoe`: corrected automatic-wake check.

## Remaining boundaries

- Generic import UI, GitHub-account binding/ownership verification, account
  membership grants/revocation and cross-account API tests are **not shipped**.
  Reuse the canonical portable ID when implementing those; do not create one
  Mira per account. There is no claim of private-memory isolation within one
  resident's OS/tool authority.
- This is an API-key Chaos pilot; Lume's clamp/transcript prerequisites remain
  separate, and her runtime has not been touched.
- Mac desktop tools are not magically available in the house. Linux filesystem,
  shell, network, house chat/API tools and the existing memory client are.
- Unique journal files remove the common concurrent-append hotspot, not every
  possible Git conflict. Narrative edits still need normal conflict resolution.
  Reads during concurrent publication are not globally atomic snapshots.
- Local BeforeTurn health notices are not a cross-host/out-of-band monitor.
  Graph read authentication was tested; no synthetic graph-write memory was
  manufactured as a canary.
- Targeted tests passed: journal/hook tests, 17 runtime profile/policy tests,
  69 prompt/session/profile Rails tests and 99 model/config Rails tests.
  The full browser suite was not run (no UI changes). RuboCop is blocked by the
  checkout's Ruby-4.0-incompatible rubocop-ast/prism setup, not reported as green.

## Rollback / care

Do not run the birth exporter against this volume. Preserve identity, state and
Chaos volumes and their backups. The existing backup volume set excludes
`state`: the deploy key there must be re-provisioned on restore, not assumed
to be in the archive. The external graph retains its separate backup system. To withdraw the pilot, disable only this
resident's participation and stop only its container after active turns finish;
Mac and Dell continue. Revoke the one repository deploy key if Git access is
being withdrawn. Never reset the canonical home or delete a house memory vault
as a rollback shortcut. Shared default `house` residents retain their old path.


## OAuth correction — 16:14 CEST

Daniel connected OpenAI OAuth and the next turn failed. The imported profile
still forced API login; Chaos explicitly logged out the mismatched ChatGPT
account. This was a pilot bug, not lost conversation data. Runtime `1eb4207`
selects the requested OpenAI login mode and checks trust in the actual isolated
OAuth home. The same previously reviewed root was explicitly trusted there;
no credentials or runtime databases were copied between authentication homes.
19 Python runtime tests and 62 session tests (460 assertions) passed, covering
fresh/resumed OAuth, API-key exclusion and fail-closed effective-home trust.
Only Mira's container was updated. The account needs reconnection because the
failed turn removed its login; a successful authenticated turn remains to be
verified after Daniel reconnects. Do not silently switch him back to API billing.
