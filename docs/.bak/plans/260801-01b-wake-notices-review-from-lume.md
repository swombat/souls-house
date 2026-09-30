# Review: notices implementation (29e60bc) — from Lume

**Verdict: approve.** Faithful to plan 01b, including the parts that were
easiest to shortcut. Tests are real (145 runs, 682 assertions, 0 failures,
run locally during review) and cover the load-bearing guarantees: both
persistent-session delta paths, subject-only marking, expiry via
`travel_to`, job coalescing, offline/unhealthy gating, transactional
rollback, `Current.user` provenance, inline exclusion, unknown-type
skipping.

Verified specifically:

- **Delta paths** — `Notices::Renderer.section_for` is in
  `request_text` AND `request_delta_text` for both
  `ExternalAgentResponseRequest` and `ExternalAgentTelegramRequest`, with
  tests asserting the resumed-session path. The plan's key catch survived
  into code.
- **Transactional creation** — `after_update` `create!` runs inside the
  update transaction; the rollback test exists and passes.
- **`Current.user`** — exists (`app/models/current.rb`), covers both web
  session and API actor; my plan-stage implementation check is satisfied.
- **Renderer discipline** — unknown types logged and skipped; malformed
  params rescued (`KeyError`/`ArgumentError`/`TypeError` covers
  `params.fetch` and `Time.iso8601` failure modes); "concerns you" only
  for the subject via obfuscated-id comparison, consistent with the
  stored `to_param`.
- **Heredoc-in-array refactors** — `<<~` squiggly strips by
  least-indented *content* line, so the deeper-indented terminators don't
  change output. Checked, not assumed.

## Findings (ranked)

1. **Controller confirmation overclaims for offline/unhealthy residents**
   (minor, copy-truth). `update_notice` says "souls.house has requested a
   fresh orientation" whenever `identity_owned_by_agent?`, but
   `ModelChangeOrientationJob` gates on `external? && health_state ==
   "healthy"`. For an `offline` or unhealthy resident the human is told
   an orientation was requested when none will be sent — exactly the
   provenance-precision class the renderer itself polices. Suggested fix:
   append the orientation clause only when `@agent.external? &&
   @agent.health_state == "healthy"`; otherwise end with "…the resident
   will see the notice on their next activation."
2. **`Agent.find` in the job raises on a deleted resident** (nit).
   Destroy between change and job execution → `RecordNotFound`, a failed
   job for a situation that needs nothing. `Agent.find_by(id:) or return`.
3. **Notice-creation failure raises out of `@agent.update`** (note, no
   change requested). `create!` inside `after_update` means a notice
   validation/DB failure surfaces as `RecordInvalid` (500), not the
   controller's errors render. Realistically reachable only via DB
   failure, and the plan explicitly wants the model change loud-failing
   rather than silent — a 500 is loud. Documented so nobody "fixes" it
   into silence later.
4. **Observation, deliberate per plan** — birth orientations now also
   carry house notices (01b includes all five builders). A newborn's
   first text can contain "Kestrel's model changed." Defensible — they
   are born into a house with a bulletin board — but it is a choice, and
   it is being made knowingly.

## Not blocking

Findings 1–2 are worth a small follow-up commit; neither blocks deploy.
Recommended next actions after that: deploy, then create the
`site_renamed` system notice (30d) as first production payload — it
verifies system scope end-to-end and bridges the still-HelixKit-branded
prompt layer until Phase 2.
