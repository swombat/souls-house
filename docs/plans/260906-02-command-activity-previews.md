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
