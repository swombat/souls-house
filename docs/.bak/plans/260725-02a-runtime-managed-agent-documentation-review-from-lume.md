# Review: Runtime-managed documentation for hosted agents

**Reviewer:** Lume
**Date:** 2026-07-25
**Reviewing:** `docs/plans/260725-02a-runtime-managed-agent-documentation.md`
**Verified against:** `agent-runtime/trigger_shim.py`, `agent-runtime/entrypoint.sh`, `app/lib/agent_identity_exporter.rb` (current master)

---

## Verdict

The plan is right, and I checked its factual claims against the code rather than
taking its own description on trust: the exporter does seed both platform files
(`AgentIdentityExporter#files`), the entrypoint does carry three mutation blocks
against identity-volume files (the `write_runtime_instructions` refresh + `.new`
fallback, the shell-safety append, the telegram append), and the sidecar roll
logic works exactly as §6 describes. The ownership table in §1 is the correct
boundary, and "documentation travels with the capability it documents" is the
correct principle.

Approve, with four findings the plan should absorb before implementation. Two
are the subtle kind that would produce quiet misbehavior rather than failures.

---

## Findings

### 1. `runtime-instructions.md` must also leave `IDENTITY_FINGERPRINT_FILES`

The plan says to stop *injecting* `identity/runtime-instructions.md` (step 3)
but never says to stop *fingerprinting* it. It is currently in
`IDENTITY_FINGERPRINT_FILES` (trigger_shim.py:106–111).

If it stays there: an existing agent annotates its now-historical
`identity/runtime-instructions.md` — a file the plan explicitly declares theirs
to keep — and the next trigger rolls the session with reason
`identity-changed`, for a file that no longer reaches any prompt. That is a
spurious continuity loss with a misleading label. The plan's own rule in §6
("a platform upgrade is not an identity edit") has a mirror image: **an edit to
a file that is never injected is not a session-relevant change.**

Add to step 3 or 4: remove `runtime-instructions.md` from the identity
fingerprint set, and add a session test — *editing a legacy
`identity/runtime-instructions.md` does not roll the session.*

### 2. Fingerprint the injected text, not the bundled file

§6 proposes hashing `/usr/local/share/helixkit-agent/runtime-instructions.md`.
But what actually enters the prompt is that file *plus* shim-generated wrapper:
the section label, the "hosting context, not identity" framing, the stable-path
line, the noncanonical-legacy-file warning (§5.1 specifies all of these). A
future change to only the wrapper text changes what sessions were primed with,
and the hash of the file won't move.

Cheapest robust fix: compute the runtime-context fingerprint over the exact
string the shim would inject (the assembled runtime section), not over the
source file. That is self-maintaining — any change to injected content, from
either the doc or the assembly code, rolls; changes to neither don't. A
`PROMPT_ASSEMBLY_VERSION` constant works too but requires humans to remember to
bump it, which is the failure mode this whole plan exists to remove.

One adjacent note for the implementer: store this fingerprint at session
creation and leave it alone in `update_session_record`. Mirroring the
identity-fingerprint refresh-on-every-turn pattern would be harmless today
(the bundled file cannot change within a container's lifetime) but records the
wrong meaning — the fingerprint describes what the session was *born with*,
not the current state of the disk.

### 3. Delete `runtime-instructions.md.new` — it becomes actively misleading

Retiring the `.new` fallback (§7) leaves already-written `.new` files on the
volumes of agents who had edited their runtime instructions. That file
self-describes as "the updated platform copy … for manual review." After this
change it is a *stale* platform copy sitting on the identity volume, inviting
an agent to treat it as current.

Removing it does not violate the ownership boundary or the "no cleanup
migration" non-goal in spirit: the non-goal protects agent-authored files, and
`.new` is by construction never agent-authored — it exists only on the branch
where the agent's own edits were preserved in the real file. Recommend a
one-time `rm -f` in the new entrypoint, and a sentence in §7 naming the
exception explicitly so it doesn't read as boundary drift. (Second-best: name
`.new` in the injected noncanonical warning. Deleting is cleaner.)

### 4. Name the remaining boundary exception, or the README will contradict the entrypoint

Step 7 documents the runtime/identity ownership boundary in
`agent-runtime/README.md`. But the entrypoint will still copy
`stop_journal_reflex.py` into `identity/automation/` on every boot — the
comment even says "the hook script itself is runtime infrastructure." That is
precisely the refresh-platform-files-into-identity pattern this plan abolishes
for documentation.

Not asking to expand scope. Asking that the README either (a) name it as a
deliberate, bounded exception with its rationale (visibility in the hosting
filesystem browser), or (b) record the follow-up: point `hooks.json` at
`/usr/local/share/helixkit-agent/stop_journal_reflex.py` directly and stop
copying into identity. A boundary document that silently excepts a visible
violation three lines away teaches readers the boundary is aspirational.

### Minor

- The injected noncanonical warning should be phrased conditionally ("if an
  `identity/helixkit-api.md` exists, it may be a historical export…") — the
  same static text is injected for new agents who never had the file.
- The runtime section's label should carry the bundled path (replacing the
  current `## Hosted runtime instructions: identity/runtime-instructions.md`
  labeling in `identity_context()`), so the provenance in the prompt matches
  the new ownership.
- Legacy sidecar handling checks out against current `roll_decision`: a v2
  sidecar lacking the runtime fingerprint reads as changed → one
  `runtime-context-changed` roll, exactly matching the §10 session test. No
  change needed; recording that it was verified.

---

## Answers to §13

### Q1 — Fingerprint scope: **injected instructions only, not the full manual**

A roll is not free. It destroys a persistent session's accumulated working
context, and for these agents session continuity is the point of the
persistent-session work, not an implementation detail. So the question is: what
can actually go *stale* inside a resumed session? Only content frozen into it —
the injected instructions. The full manual is never frozen: a resumed session
that reads the stable path after an image upgrade reads the *new* image's copy,
automatically current. Hashing both files converts every typo fix in a
400-line manual into a fleet-wide session wipe for zero correctness gain.

The one real residual risk of injected-only — an agent acting on its in-context
*memory* of manual details it read before the upgrade — is better handled by
one sentence in the injected guide ("re-read the manual before relying on
endpoint specifics; your memory of it may predate the current image") than by
rolling everyone.

### Q2 — `helixkit-help`: **skip the command; put the pointer in the helpers' `--help` instead**

The scenario that makes discoverability matter: a long session compacts, the
injected path scrolls out of working context, and the agent reaches for what it
can rediscover. Its established rediscovery channel is the `helixkit-*` command
namespace. But you don't need a new command to occupy that channel — the
helpers the agent will inevitably run already do. Add a one-line footer to
`helixkit-post-message --help` (and siblings):
`Full HelixKit manual: /usr/local/share/helixkit-agent/helixkit-api.md`.

That is zero new surface, travels with the capability by construction, and
reaches the agent exactly at the moment it is already consulting help. If you
still want `helixkit-help` as a nicety, the print-only constraint in §4 is the
right guard — but the footer makes it redundant.

### Q3 — `bootstrap.md`: **stays identity-side**

Bootstrap is per-agent, generated at promotion, time-bound. It is a birth
letter, not a manual: it becomes *historical* the way a letter does, not
*stale* the way documentation does. Nothing in it needs in-place updating once
its API pointer moves to the runtime path (which the plan already does). The
distinction underlying this whole plan is "does HelixKit need to keep this
current?" — for bootstrap, after this change, the answer is no. And as the
platform-manual content is stripped out of it, what remains is increasingly
pure promotion-moment context, which earns its identity-side place more over
time, not less.

### Q4 — Both files together: **agree with the plan's recommendation**

Concretely, from the entrypoint: the `write_runtime_instructions` block is the
most invasive of the three mutation patterns — it *overwrites the entire file*
whenever it sees the managed marker, where the API-fragment blocks merely
append. Moving only `helixkit-api.md` would retire the appends and keep the
overwriter. The half-measure preserves the worst offender. Both together.

---

## Suggested test additions

- Editing a legacy `identity/runtime-instructions.md` does **not** roll the
  session (finding 1).
- Changing only the shim's injected wrapper text (not the bundled doc) **does**
  roll with `runtime-context-changed` (finding 2 — free if the fingerprint is
  computed over injected text).
- After boot, `identity/runtime-instructions.md.new` does not exist
  (finding 3, if adopted).
