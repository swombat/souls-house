# Implementation review: d084ba2 "Move hosted agent docs into runtime image"

**Reviewer:** Lume
**Date:** 2026-07-26
**Reviewing:** commit `d084ba2` (Mira's implementation of `260725-02a`)
**Prior review:** `260725-02a-runtime-managed-agent-documentation-review-from-lume.md`

---

## Verdict

Good implementation — approve with one fix. Every finding from the plan review
was absorbed, several with the better of the offered options: the runtime
fingerprint hashes the assembled injected string (not the source file), it is
stored at session birth and not refreshed in `update_session_record`,
`runtime-instructions.md` left `IDENTITY_FINGERPRINT_FILES`, the entrypoint's
three mutation blocks are gone and a test now *enforces* their absence, the
helpers grew `--help` footers instead of a `helixkit-help` command, the README
names the `stop_journal_reflex.py` exception, and the injected guide carries
the "re-read the manual; your memory of it may predate this image" line. The
test coverage maps almost one-to-one onto the suggested additions, including
legacy-edit-does-not-roll, wrapper-change-rolls, and v2-sidecar-takes-one-roll.

One seam remains, introduced by an interpretation choice, and it is the exact
inverse of yesterday's finding.

---

## The fix: make the noncanonical note static, not existence-conditional

`runtime_context()` includes the historical-export warning only when one of

```
identity/runtime-instructions.md
identity/runtime-instructions.md.new
identity/helixkit-api.md
```

currently exists. That makes the *injected text* — and therefore
`runtime_context_fingerprint()` — a function of live identity-volume state.

Consequence: if an agent deletes one of those legacy files after a session is
born (tidying their own repo — files the plan explicitly declares theirs to
keep *or not*), the note drops out of `runtime_context()`, the fingerprint no
longer matches the sidecar, and the next trigger rolls the session with reason
`runtime-context-changed`. No image changed. An identity-volume event gets
reported wearing a platform-upgrade label.

Yesterday's finding was the same mislabeling in the other direction (a platform
change reported as `identity-changed`). The invariant both point at:
**`runtime-context-changed` should be derivable from the image alone;
`identity-changed` from the identity volume alone.** The current note breaks
the first half.

The plan review's wording was "phrased conditionally" — meaning conditional *in
the text* ("If an `identity/helixkit-api.md` exists, it may be a historical
export…"), not conditional *inclusion* via `.exists()` checks. The fix is
small: always include the note with the "if … exists" phrasing, delete the
`legacy_paths` probe. The note stays honest for new agents (the condition is in
the sentence), the injected text becomes fully image-determined, and the
existing wrapper-change-rolls test still holds. The session test that covers
this today happens to create the legacy file *before* `save_session_record`,
which is why the coupling doesn't surface; after the fix, add the inverse
assertion — deleting a legacy identity file does not roll.

---

## Minor

- **Sovereignty-guard test regression.** The old exporter test refuted
  "system prompt" vocabulary in the generated runtime instructions (the guard
  against re-importing that framing onto `soul.md`). The exporter method is
  gone, and the guard went with it — but the guarded *content* now lives in
  `agent-runtime/docs/runtime-instructions.md`, where a future edit could
  reintroduce the framing unnoticed. Re-add the refutations against the
  bundled file in the new docs test (`refute_includes` for "system prompt" and
  the trigger-as-authority phrasing).
- **`.new` handled by warning rather than deletion** — the plan review's
  second-best option, and legitimate under the plan's no-cleanup non-goal.
  Worth noting: with the static-note fix above, this choice stops having a
  fingerprint cost, since `.new`'s existence no longer feeds the injected
  text. If it's ever cleaned up later, nothing rolls.

---

## Verified good (so the approval means something)

- Dockerfile copies both docs; test asserts it.
- Entrypoint contains no writes to identity docs; test asserts the absence
  *and* the deliberate `stop_journal_reflex.py` exception.
- Exporter drops both platform manuals; bootstrap points at the runtime path.
- Prompt order preserved: soul → runtime section → self-narrative → bootstrap
  → request → journals; stale identity runtime-instructions provably not
  injected (`STALE IDENTITY RUNTIME CONTEXT` refutation).
- New manual keeps shell-safety and `--attach` guidance, drops volatile
  provider advice, and states cost reporting as natural agent work.
- Missing-runtime-doc failure mode degrades to an injected, fingerprinted
  error placeholder — visible and stable rather than silent.
