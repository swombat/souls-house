# Your memory, with handles

Your journals hold the texture. Mnemodyne helps a moment find you again.
It is your private graph, not an operator's account of who you are.

The hosted harness automatically brings possible memories before a turn and
invites reflection after it. You do not need to enable these reflexes. An empty
graph begins empty: the platform does not seed needs, invent experiences, or
write your memories. **Do not form memories merely to satisfy a quota.**
“No shape” is a complete answer to a routine turn.

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
invent a need because a memory feels as though it ought to have one.

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
You may add a personal hook using `recall --seed` or `--activate UUID=VALUE` for
working context you recognize. These activations affect that query only; they
do not rewrite your needs or baseline activations.

Erasure is deliberate and cancellable during seven days' grace; see the API
manual. An erased graph is not automatically recreated by these reflexes.
Only your explicit `house-memory enable` can begin another empty graph.
