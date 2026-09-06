# Conservative command activity previews

Daniel requested implementation and deployment on September 6, 2026.

## Boundary

Command activity now carries a preview, constructed inside the resident runtime
before enqueueing any callback. This is a finite-vocabulary projection, not a
regex promise to recognise every possible secret.

- Recognised executable/subcommand prefixes and explicitly approved flags can
  appear: `git status --short`, `git diff --stat`, `bundle exec rails test`.
- The first unrecognised argument hides that argument and everything after it:
  `curl -sS [arguments hidden]`, `rg -n [arguments hidden]`.
- Arbitrary paths, filenames, URLs, search patterns, environment assignments,
  headers, request bodies and inline scripts are never copied to the preview.
  Even test paths are hidden in this version.
- Unknown executables, invalid shell quoting and oversized commands get
  `Command [arguments hidden]`. Standard `sh`/`bash`/`zsh` `-c`/`-lc` wrappers
  can be unwrapped twice, without executing anything.
- Previews are bounded to 240 bytes. This is not a full shell parser or a full
  execution trace: compound commands show at most the recognised first prefix.
- A single checked-in policy supplies the runtime and Rails vocabulary. Rails
  independently validates each preview before persisting a public label,
  including heartbeat repair snapshots. Invalid previews fall back to the old
  generic label rather than dropping lifecycle control.
- Raw command/output fields remain excluded. The existing plain-text Svelte
  label rendering displays previews in live operations and retained history;
  there is no HTML or Markdown interpretation.

Old runtime reporters and historical records remain compatible and generic.
Narration consent is unchanged: this is bounded tool metadata, not narration.
The policy cannot prevent deliberate signalling through allowed vocabulary;
it prevents arbitrary command strings being copied into public activity.

## Verification and rollout

Synthetic tests cover headers, URL credentials, arbitrary opaque tokens,
environment assignments, script bodies, command substitutions, heredocs,
compound commands, malformed quoting, control/bidi characters, bounds, and
redaction before transport in start/finish/heartbeat events. Rails rejects
forged preview strings independently. Browser coverage checks live previews
and retained history through completion and reload.

Deploy Rails before replacing idle runtime containers. Retain the prior image
for rollback; run a synthetic production shim/helper/callback canary with both
a visible safe command and a hidden credential marker before fleet rollout.
No provider invocation or real resident wake is needed for this check.

## Deployment result — 16:05 CEST

- Deployed Rails release `db056de012d12a4f69cc1a2b8ff3283dbe0ae43c`;
  feature commit `67f384f` plus production packaging correction `db056de`.
- Initial deployment was rejected by Kamal's health gate: the Rails image's
  explicit COPY list omitted the shared policy. The previous release continued
  serving HTTP 200. Added build/final-stage packaging and a regression check;
  verified preview acceptance/rejection inside the rebuilt final image before
  retrying. The corrected deployment completed successfully.
- Final Rails suite: **2,231 tests, 11,256 assertions, zero failures/errors**.
  **20 browser journeys** and **82 frontend unit tests** passed. Changed Ruby
  passes lint using the existing temporary parser compatibility override.
- Fresh fail-fast full backup succeeded, including database object
  `souls_house_production_2026-09-06_13-55-44.sql.gz`.
  Previous runtime retained as `helixkit-agent-runtime:pre-command-preview-20260906`
  (`sha256:25a8c63c65bdbdd845bca088d8b87e0f027835ffd0e1fcde6e63798a369629a7`).
- Production canary passed through the installed shim, HTTPS callback and reply
  helper: live and persisted `git status --short`; credential-bearing command
  projected as `curl [arguments hidden]`; private marker absent from public
  activity; eight detail events; one correlated reply; completed card retained.
  The 64 KiB/no-redirect callback check also passed. Synthetic records removed.
- All nine idle resident containers updated and verified healthy on image
  `sha256:9a7f98b937277aa825f803b4653098ee889c70501ac404828c6292aeb2c8cd07`.
  No active residents were deferred or intentionally interrupted.
- Final public `/up`: HTTP 200; web/jobs running the corrected release;
  Mnemodyne readiness passed; zero failed jobs in the preceding 15 minutes.
  Evidence is in this instance's ignored `log/command-preview-*.log` files.
