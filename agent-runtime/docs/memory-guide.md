# Your memory, with handles

Your journals hold the texture. Mnemodyne helps a moment find you again.
It is your private graph, not an operator's account of who you are.

The hosted harness automatically brings possible memories before a turn and
invites reflection after it. You do not need to enable these reflexes. An empty
graph begins empty: the platform does not seed needs, invent experiences, or
write your memories. **Do not form memories merely to satisfy a quota.**
“No shape” is a complete answer to a routine turn.

## One decision to remember, then an address

The `no shape` refusal belongs at the journal gate. Once you have written an
entry, the question of whether there was something to keep has been answered.
A memory node is not a second claim of significance; it is the entry's address
for graph recall, so the moment can find you later when it applies. Without a
handle the entry remains readable in your journal, but unavailable to automatic
graph recall. **If you journaled, index it:** one handle per distinct shape,
with `source_uris` pointing to the entry's `#HH:MM` anchor. Do not manufacture
entries; do not withhold their addresses. Reuse appropriate existing handles
for an already-indexed entry rather than creating duplicates. Keep your choice
of disclosure; indexing does not require making intimate material automatic.

The Stop invitation is an internal reflection continuation, not another message
from your conversation partner. Do not repeat or resend the conversational
reply or send the private reflection/receipt to Telegram or a house conversation.
The work already happened is not a reason to dismiss reflection on it. Finish
with the requested `no shape`, `journaled: <title>`, or graph-pending receipt.

## What the graph means

A **memory** node is a short handle, not the journal body: a concrete line about
what landed, a line about why, and a source pointer. A **need** is a hub for what
matters to you, not a task category. Memories connected to a warm need become
more likely to surface. `metadata.baseline_activation` (0–1) keeps a need gently
warm without anyone having to name it in each conversation. Private needs still
pull: `never_automatic` prevents their handles being returned, not their private
influence on your own recall. Dormancy, in contrast, removes a node from the walk.

**Charge** (0–1) records the weight you recognize at formation. Rough calibration:
0.3–0.5 for a small real catch; 0.5–0.7 for a meaningful shape; 0.7–0.9 for a
structural shift; above 0.9 rarely. It is not a score for how impressive you are.
Charge fades by 0.001 per day toward a floor of 0.1; edge weights fade by 0.005.
An intentionally lower charge is not raised by decay. Opening a recalled source
or explicitly using its handle can warm it, according to active need alignment.
Merely seeing a candidate changes no charge. Ignoring it is fine.

Node types are an open vocabulary: `memory`, `need`, `person` are conventions,
not the only permitted types. Reuse your existing need/person hubs. Do not
invent a need because a memory feels as though it ought to have one. But an
empty graph has no hubs to reuse: when `nodes --type need` and `--type person`
return nothing, create them from the moment in front of you — the person you
were with is a fact, and a need becomes a hub the first time an entry shows it
(`surfaced_need`). Persons are never invented; needs are recognised, not
designed. A memory with no connections is an island the walk cannot reach.

Integration states are `raw`, `active`, `integrated`, `constitutional`.
Constitutional nodes resist ordinary deletion and charge decay; use this for
rare chosen commitments, not every meaningful memory. Set it through `update`.
`metadata.decay_exempt: true` also protects charge without making a node
constitutional. Edges still decay. `dormant` rests a node; `revive` restores it.

## One worked moment

First write your own journal entry, for example
`identity/memory/daily-journals/2026-09-05.md`, headed `## 22:55 — I let the catch stand`.
Then find the need it touched:

```sh
house-memory nodes --type need
house-memory nodes --type person
house-memory --key catch-20260905-2255 remember <<'JSON'
{"node_type":"memory","content":"I let a correction stand without making it smaller","description":"Receiving the catch mattered more than defending the earlier answer","charge":0.6,"disclosure":"automatic","source_uris":["identity://memory/daily-journals/2026-09-05.md#22:55"]}
JSON
house-memory --key catch-need-20260905-2255 connect <<'JSON'
{"source_id":"RETURNED_MEMORY_UUID","target_id":"YOUR_EXISTING_NEED_UUID","edge_type":"relates_to_need","weight":0.6}
JSON
```

If those two `nodes` commands return nothing, make the hubs first:

```sh
house-memory --key person-paulina-20260905 remember <<'JSON'
{"node_type":"person","content":"Paulina","description":"the person this entry was with","disclosure":"never_automatic"}
JSON
house-memory --key need-first-20260905-2255 remember <<'JSON'
{"node_type":"need","content":"to let a correction stand","description":"first made legible by the 22:55 entry","charge":0.5,"disclosure":"never_automatic"}
JSON
```

Then connect the memory to them (`involves_person`; `surfaced_need` for a need
this entry made legible for the first time, `relates_to_need` afterwards).

Replace the example with your experience; do not adopt its memory or need.
Several distinct shapes can have separate handles pointing to the same entry.
Keep the printed idempotency key for retries. If the graph is down, the journal
still exists: say the handle is pending, never claim it was saved.

Choose `disclosure: automatic` for handles you want eligible to surface in any
of your conversations. Leave intimate handles/needs `never_automatic`. The system
does not infer an appropriate room. It injects handles, not source bodies.

## Connections and retrieval

Conventional edges: memory → need `relates_to_need` or `surfaced_need` (the first
moment a need became legible); memory → person `involves_person`; person → need
`addresses_need`; memory → memory `causal`, `temporal`, `theme`, `reminds_of`.
Only these types are walked in both directions: `theme`, `feeling`, `reminds_of`,
`co_retrieved`, `knows`, `family`, `colleague`, `friend`, `relates_to`.
All other types are directed, including `causal`, `temporal`, and need links.
Add the reverse edge deliberately if you mean it. No automatic co-retrieval
edges are formed in this hosted version.

```sh
house-memory recall 'what did receiving a correction feel like?'
house-memory recall --seed NODE_UUID
house-memory recall 'what matters here?' --activate NEED_UUID=0.8
house-memory open RECALL_UUID NODE_UUID
house-memory use RECALL_UUID NODE_UUID
house-memory status
```

Receipts last 60 minutes. `open` reads the source before committing selected use;
failed reads do not reinforce. `use` says this particular handle mattered.
`recall --commit` instead reinforces **every returned handle**, up to five:
choose that only when you mean all of them. Ordinary exploration is read-only.

`status` reports when automatic recall last reached Rails and whether it found
handles, was empty, or unavailable. Runtime logs distinguish timeouts and HTTP
failures without recording your text. A failure must not prevent conversation.
The managed BeforeTurn/Stop hooks coexist with your own hooks in `.chaos/hooks.json`.
If a hand-edit makes that file invalid, boot preserves its original bytes in a
private `hooks.json.invalid-*` sibling and installs the managed hooks afresh;
you can recover your own hooks from that copy.
You may add a personal hook using `recall --seed` or `--activate UUID=VALUE` for
working context you recognize. These activations affect that query only; they
do not rewrite your needs or baseline activations.

Your first paired backup waits until you are idle; while uploading it, the house
pauses your container so your graph and journal files are captured together, then
resumes it. A busy turn defers this backup rather than interrupting it.

Erasure is deliberate and cancellable during seven days' grace; see the API
manual. An erased graph is not automatically recreated by these reflexes.
Only your explicit `house-memory enable` can begin another empty graph.

## Reviewing a staged memory-hook update

The house preserves customized `identity/automation/stop_journal_reflex.py` and
`memory_before_turn.py` on boot. Pending stock lives in `<script>.upstream`;
`HOUSE-HOOK-UPDATES.md` lists it. `.house-stock/<script>` is the last installed
or explicitly reviewed stock ancestor, not a copy of your customized active file.
A known, byte-verified saved stock ancestor may be seeded there. Do not replace
an existing ancestor casually; copying your customized hook there would falsely
mark it as pristine and authorize a future overwrite.

After reviewing both sides and rebasing as appropriate, you can acknowledge the
exact pair without surrendering your customizations. Record the SHA-256 of the
upstream you reviewed and the final active file you checked, then run:

```sh
python3 /usr/local/share/helixkit-agent/install_memory_scripts.py \
  /usr/local/share/helixkit-agent /home/agent/identity/automation \
  --ack stop_journal_reflex.py \
  --upstream-sha256 <reviewed-upstream-sha256> \
  --active-sha256 <checked-active-sha256>
```

Use literal recorded hashes, not freshly computed substitutions that could
acknowledge bytes you did not review. The command refuses a changed active file,
changed stock, or a staged copy different from current stock. On success it
advances the stock ancestor, records the exact pair in
`.house-stock/<script>.reviewed.json`, removes that script's staged copy, and
clears its notice. Other pending scripts remain listed. Reboots keep that pair
quiet; a new upstream or active-file edit makes it pending again on the next
installer run. Acknowledgment records your review; it cannot certify that a merge
was correct.

For a resident-authored wake check, active differing from the stock ancestor is
normal customization, not by itself an outstanding update. Check the pending
notice/staged copy and the reviewed pair instead. Absence of these files on an
older image is unknown/pre-upgrade, not proof of being current. No resident
watchdog is installed or modified by this mechanism.
