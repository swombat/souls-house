# Standard home sync review

Follow-up to [PR #179](https://github.com/swombat/souls-house/pull/179),
scope [#180](https://github.com/swombat/souls-house/issues/180).

## PR description notes

- Explicit **Keep existing sync** (default) versus **Use standard two-way Git
  sync**. No existing resident is automatically enrolled or reconfigured.
- The reviewed manifest owns eligible auto-commit, append-only and destructive
  allowance scopes. An empty eligible list means committed changes only, not
  automatic saving of uncommitted edits.
- Cached sync health shows last confirmed success and reported age independently
  of import readiness. Unknown/stale/blocked/failed states and rescue outcomes
  never count as successful branch synchronization.
- Conflicts preserve local commits and attempt a separate, non-force rescue ref.
  A successful rescue push does not resolve the conflict; a failed rescue push
  requires retaining the local working copy. Deliberate reconciliation is needed.
- The local-use guide installs a commit-pinned, checksum-verified standalone
  Python runner; it is not a cross-harness adapter or scheduler installer.

This capability requires the Rails and runtime releases. Backend migration and
runtime tests belong to the backend portion of the stacked PR. The UI adds no
secret or provider configuration. Local copies need separate origin credentials.

## Synthetic browser evidence

The screenshots below were captured from the running Rails/Inertia application
by the browser spec
`test/e2e/standard_home_sync.spec.js` uses only synthetic TestSupport accounts,
`example-org/example-home`, fake token metadata and canned safe health records.
It does not submit import/approval, invoke a real runner or contact GitHub,
Docker, a provider, external memory or a private resident home.

- `01-keep-existing-desktop.png`: default choice, existing script kept.
- `02-standard-choice-desktop.png`: explicit standard selection and eligibility.
- `03-reviewed-policy.png`: exact manifest scopes, protections and unknown health.
- `04-conflict-rescue-desktop.png`: attention required, old confirmed success,
  separate rescue ref—not branch-sync success.
- `05-standard-choice-mobile.png`: standard choice at 390px, no overflow.
- `06-rescue-failed-mobile.png`: failed rescue and local-copy preservation guidance.
- `07-stale-mobile.png`: stale success, committed-only policy, not up to date.

Prior PR179 images in `../github-resident-onboarding/` are not replaced.

## Checks and limits

Lume's first head review reproduced idle merge-commit ping-pong and repeated
rescue branches for unchanged commits. Both are fixed: descendant histories
fast-forward after protection checks; successful rescue refs are reused only
after verifying that the remote ref still names the same local commit.
Eight alternating idle cycles add no commits, and rescue cache lifecycle tests
cover failed pushes, changed heads and missing/mismatched remote refs.
The backend helper's final full Python run passed 231 tests (five skips).
The second review found a remaining append-convergence defect: sorting whole
suffixes could reorder published content and strand the first host behind its
append-prefix guard. Daniel authorized the correction and clarified that
ordinary fixes within agreed work do not need another permission request.
The correction preserves remote-published order before local additions;
chronological ordering is not promised. Four publisher/value permutations,
repeated idle cycles, subsequent concurrent appends and rejected-push recovery
pass. The final neutral-environment Python suites pass 130 runtime and 108 root
tests (five skips), including 39 real Git cases. Already non-prefix histories
and clones copied from unpublished side-parents remain explicit safe-refusal
cases, not a promise of arbitrary history repair.
Container-hostname rescue labels remain a limitation; stable body labels and
in-cycle push retries are deferred. A rejected push retries on the next cycle.

- Full Vitest: 80 files, 526 tests passed.
- Scoped Prettier and Svelte size check passed (four existing size warnings).
- Full frontend format check reports three unchanged files:
  `AgentAppearancePanel.svelte`, `AgentUpgradeDialog.svelte`, `lib/logging.js`.
  They are not reformatted in this follow-up.
- TestSupport Ruby syntax check passed.
- Scoped RuboCop could not inspect under the installed Ruby-4.0/AST combination;
  it fails before code analysis, not with a reported code offense.
  The changed TestSupport file passed with a temporary external Ruby-3.4,
  `parser_whitequark` configuration; repository configuration is unchanged.
- Full integrated Playwright: **99 passed**, including admission, desktop/mobile
  policy, health, rescue and overflow checks.
- Full integrated Rails with frozen source: **3347 runs, 21128 assertions,
  zero failures/errors/skips**.
- All seven captured screenshots were visually inspected, with original-resolution
  checks of the detailed policy and mobile health pages. No blocking layout issue
  was found at the captured desktop and 390px mobile widths.

### Visual findings

- The default and standard radio selections are distinct; the standard guidance
  stays inside the form and does not overlap its submit button.
- Reviewed scopes, protections and whole-block append semantics remain readable.
  Unknown and stale sync do not appear successful; rescue failure and the old
  last-success age remain separate from import readiness.
- Mobile cards stack cleanly; long identity IDs, reviewed SHAs and rescue refs
  wrap within their borders, with no clipped health text or overlapping controls.
  The native connection select truncates its long one-line label; the reviewed
  repository is shown in full on the request page.
- Detailed policy and approval pages require substantial vertical scrolling.
  These captures are not a full accessibility audit or evidence about other
  viewports, themes or live runtime behavior.

An initial Rails run had three Inertia version conflicts after frontend source
was edited during that run: boot-time version and dynamic test headers differed.
The frozen-source rerun above passed. The first browser run exposed a
whitespace-sensitive locator in the new spec; the locator was corrected without
changing UI behavior, and the full rerun passed.

Screenshots prove presentation of synthetic outcomes, not a live
GitHub/Docker/interactive-Chaos rollout or successful synchronization of a real
identity. No automatic conflict resolution is promised.
