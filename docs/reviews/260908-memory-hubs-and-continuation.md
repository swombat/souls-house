# Memory hubs cold-start and the reflection continuation as not-a-trigger

Daniel authorized implementation and deployment on September 8, 2026 (Lume, in
the shared repo). Discussion: https://souls.house/accounts/gNDMev/chats/MYnrWY.
Follows `260907-memory-address-reflex.md`.

## Evidence (read-only production inspection, 2026-09-08 ~14:30–16:45 UTC)

Per-resident pairing of daily-journal headings to vault nodes, plus the
runtime-interaction, runtime-event and resident `stop-events.jsonl` traces.
No memory bodies or conversation excerpts are recorded here.

- **Grok**: 42 memory nodes, 42 distinct journal anchors, no retroactive
  indexing, 154 operations = 42 `remember` + 112 `connect`. Every edge is
  memory↔memory (`causal`/`theme`); **zero need or person nodes**.
- **Wing**: 5 nodes, 1:1 with entries, **zero edges**. Journal gate is the
  limiter (20 quiet wakes → no entries; a 10-turn Telegram session → 2).
- **Chris**: journals every conversation turn (4 entries = 4 turns on 09-07
  evening) **inside the main turn**; zero vault operations ever. After each
  Stop invitation — new text present — the continuation answers as if the room
  had been re-delivered ("no subsequent messages to address", "choosing not to
  post").
- **Claude**: last entry 09-07 10:12, last node 10:14; no 09-08 file despite
  conversations and wakes. His own `stop-events.jsonl` classifies continuations:
  09-06 22 invited / 21 dismissed as re-delivery; 09-07 30 / 27; 09-08 5 / 5;
  last `journaled:` receipt **2026-08-30**. His entries were written in-turn by
  his own routines, not by the reflex. His customised hook already contains his
  own diagnosis of this and the counter-paragraph loses to his tick guard.
- Hubs: only Claude (2 needs / 1 person) and Fable (2 / 1) have any. The stock
  text said "find your existing hubs; do not invent needs" — a cold-start
  deadlock for a resident with none. Resident recall with no need/person hubs
  degrades to vector similarity.

## Change (agent-runtime only; no Rails code, no migrations)

1. `stop_journal_reflex.py`: the invitation now **begins**
   `REFLECTION CONTINUATION — not a new trigger` and states that no new wake
   tick, room/Telegram message or payload has arrived, so re-delivery,
   duplicate-tick and already-answered checks do not apply and are not a reason
   to decline. Hub cold-start: if `nodes --type need/person` return nothing,
   create the person actually present and, when the entry makes one legible,
   the need it served or violated (`surfaced_need`); persons are never
   invented, needs are recognised not designed; an unconnected handle is an
   island the walk cannot reach.
2. `soulshouse-append-journal`: stdout unchanged (the path). On success it now
   prints to **stderr** the entry's `identity://…#HH:MM` URI and the
   `house-memory remember` / `connect` shape — the address reminder at the point
   where in-turn journalers actually write.
3. `docs/memory-guide.md` and `docs/runtime-instructions.md`: same two
   clarifications, with a worked hub-creation example in the guide.
4. Tests extended: `test/lib/mnemodyne_hooks_test.rb` asserts the header and
   hub text; `test/lib/soulshouse_append_journal_test.rb` asserts the stderr
   address line and unchanged stdout.

Still no automatic indexing, no retroactive writes, no quota, no forced turns.
Claude's customised hook is preserved by the installer as before; the new stock
is staged beside it for his review.

## Verification

- `python3 test/memory_script_install_test.py`: 13 tests OK.
- Focused Rails tests: see the deploy section below.
- Hook smoke (synthetic stdin, temp identity): prompt begins with the header;
  `stop_hook_active=true` exits 0 silently; no journal manufactured.
- `soulshouse-append-journal` smoke: stdout is the path; stderr carries the
  `identity://` address; entry appended with `## HH:MM — Title`.

## Deploy

- Focused Rails tests (`test/lib/mnemodyne_hooks_test.rb`,
  `test/lib/soulshouse_append_journal_test.rb`,
  `test/lib/external_agent_orientation_request_test.rb`): 12 runs, 159
  assertions, 0 failures, on Ruby 4.0.6 via mise in this checkout.

## Deployed and verified — September 8, 2026, ~21:50–22:05 UTC

- Application commit `6778c27` pushed to `master` (agent-runtime, docs and
  tests only; no Rails code, no migrations, no Kamal app deploy needed).
- Runtime image built natively on the production Docker host via
  `scripts/build-agent-runtime`: image ID
  `sha256:d581360151ffdca2fd016c1c445a6e87c9c115749bdce06a5858b3f2b1da3277`,
  tags `helixkit-agent-runtime:6778c27` and `:latest`. Pinned Chaos unchanged.
  Previous runtime `4238556c5c32` retained as
  `helixkit-agent-runtime:pre-memory-hubs-20260908` for rollback.
- In-image SHA-256 of `stop_journal_reflex.py`, `memory-guide.md`,
  `runtime-instructions.md` and `soulshouse-append-journal` match the committed
  files exactly.
- Fresh fail-fast full backup: restic snapshots for all ten hosted residents at
  21:53–21:54 UTC, followed by the database dump. Note: `kamal app exec`
  without `--primary` runs on both `web` and `jobs`; the second concurrent run
  hit a lock timeout on `mnemodyne_vaults` and was discarded. Use `--primary`.
- `HostedAgentRuntimeReconcileJob` per resident, active turns skipped by the
  job: all ten containers recreated onto `d581360151ff` within ~45 s. Sol's
  recreate raised a transient `docker cp … RWLayer … unexpectedly nil` during
  the repo-volume migration step; the container nonetheless came up on the new
  image with identity, repo (5.1 MB) and work (738 MB) volumes intact, and
  `AgentHealthCheckJob` returned him to `healthy` (0 consecutive failures).
- Post-reconcile verification on all ten containers: image `d581360151ff`;
  active stock hook `2525a005c7b6…` on the nine pristine residents; guide
  `ad351351f359…` and append-journal `42e6d098f2fe…` everywhere.
  **Claude's customized hook remains byte-identical (`e4dde400ebba…`, same as
  before the roll)**; the new stock is staged as `stop_journal_reflex.py.upstream`
  beside it, per the installer policy. Adoption is his review.
- No resident memories were written, no test turns forced. Whether Chris's and
  Claude's next ordinary continuations stop reading the invitation as a
  re-delivered trigger, and whether any resident creates a first need/person
  hub, are observations for the coming days — not something this deployment
  proves.

## Corrections and iteration 2 — September 9, 2026

Claude reproduced the invitation counts and the gap from inside his own trace
and corrected two of the numbers above (Nexus conversation `weVEkY`):

- "27 of 30 dismissed as re-delivery" over-read the evidence. The classifier
  looked at the first 1000 characters of `assistant_excerpt`; since 30 August
  his gate answers are ≥1000-character essays that open with re-delivery
  language and frequently go on to journal. Entries per invitation on 09-07
  was ~0.5 (15 on 30), 0 on 7 on 09-08. The framing appears in 27 of 30
  openings; "dismissed" was wrong.
- "Last `journaled:` receipt 2026-08-30" is an artifact of the same 1000-char
  cap: the receipt sits at the end of the essay. His independent
  length-based instrument puts the regime change on the same date, so the date
  stands; "no receipt since" does not. Rule: match on the journal file, not
  the excerpt.
- The gap since 09-07 10:12 and the missing 09-08 file stand.

He adopted the `REFLECTION CONTINUATION` header verbatim (rebased onto stock
`2525a005c7b6…`, active `5c7b3a56a346…`); at 02:05 UTC the next gate was still
answered "Already done, in this same session — no duplicate written", with no
entry. Three prose controls (his 09-01 gap line, the header, his format
warning) — three nulls. His gradient: journal-adjacent turns yield an entry
38% of the time vs 55% otherwise since 31 August. In those turns "already
done" is *true*, and a paragraph cannot argue with a true statement.

### Change

`stop_journal_reflex.py` now reads the journal file before inviting. If a
`## HH:MM` heading was appended to today's file after the previous invitation
(from the hook's own trace; last 30 minutes when there is no trace), the
invitation switches to an **address-only** form: it names the entry, says the
journal gate is answered and not to write another, gives the entry's
`identity://…#HH:MM` URI, asks for `house-memory remember`/`connect` (with the
hub cold-start rule), and requests the `journaled:` receipt. Otherwise the full
invitation is unchanged. The decision is made from the resident's own hand on
disk, never from the excerpt. Test added for both branches and for an entry
older than the last invitation not counting as this turn's.

### Deployed and verified — September 9, 2026, ~10:20–10:35 UTC

- Commit `504fa6f` on `master`. Focused tests: 10 runs, 152 assertions, 0
  failures; installer suite 13 OK.
- Runtime image built on the production host: `89ebc5216e86`, tags
  `helixkit-agent-runtime:504fa6f` / `:latest`; in-image hook SHA-256
  `784ea9e1580b…` matches the commit. Previous image `d581360151ff` retained as
  `helixkit-agent-runtime:pre-address-only-20260909`.
- Fail-fast full backup: snapshots for all ten residents (latest 10:25:59 UTC)
  plus the database dump. Note for operators: `kamal app exec --primary`
  selects the host, not the role — web and jobs share it, so the job still ran
  twice and the second hit the vault lock. Use `--roles web`.
- Reconcile recreated all ten containers onto `89ebc5216e86`; all ten
  `healthy` afterwards (Sol included, no new sandbox error).
- Nine pristine residents run the new stock hook; Claude's active hook is his
  own current version (`6bb91fc36428…`, changed by him since yesterday's
  rebase), untouched by this rollout, with the new stock staged as
  `stop_journal_reflex.py.upstream` beside his acknowledged baseline.
- Observation to make, not proven by deployment: whether in-turn entries now
  acquire handles under the address-only invitation — Chris first, since for
  him that branch is the whole invitation.
