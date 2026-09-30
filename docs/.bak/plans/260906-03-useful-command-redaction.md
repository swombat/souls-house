# Useful command previews with best-effort redaction

Supersedes the finite-vocabulary policy in 260906-02. Daniel's production
examples showed that hiding all arguments left the feature largely useless.
He explicitly approved the best-effort trade-off on September 6, 2026.

## What is visible

Ordinary executable names, flags, file paths and search terms, including
`cat app/models/agent.rb` and `grep -n runtime app/services/agent_dispatch.rb`.
Shell wrappers are unwrapped without execution; ordinary compound commands
retain their separators. Arguments containing spaces are quoted for display.
Live operations, heartbeat repair and retained history use the same preview.
The existing Svelte plain-text rendering is retained, with wrapping for longer
labels.

## What is redacted

Redaction happens before the runtime reporter enqueues callbacks. Known runtime
credential values, credential-like token patterns, environment assignments,
authentication headers/options, URL userinfo/query/fragment, request bodies and
inline interpreter expressions are hidden. Malformed, oversized or opaque shell
expansions fall back to a hidden-payload label. No raw tool output is published.
Previews are bounded to approximately 1 KiB after redaction.

Rails independently reapplies credential/option redaction and rejects control
characters and oversized fields. Shared JSON defines credential patterns and
sensitive options; runtime parsing uses Python shlex, Rails uses Shellwords.
Neither parser executes any command.

**This is not guaranteed secret detection.** Arbitrary short secrets read from
files, disguised/encoded credentials and sensitive ordinary prose may not be
recognisable. File paths and search strings can themselves reveal information.
That is the explicitly accepted usefulness/privacy trade-off, not something
the presence of a redaction filter eliminates.

Existing generic history cannot be recovered from activity records. Old
reporters remain compatible until replaced. Narration consent is unchanged.

## Verification

Tests must prove both useful paths/search terms survive and sensitive values
are removed: shell wrappers, compound commands, quoted searches, headers, URL
credentials, environment assignments, known credentials, opaque bodies/scripts,
malformed quoting, control characters, bounds and start/finish/heartbeat
transport. Browser coverage checks a meaningful search command before and
after completion/reload. Production canary must use the same meaningful command,
not merely `git status`, and a synthetic credential-bearing curl command.

## Rollout verified — 17:54 CEST

- Feature `546d0a7`, deployed merge
  `fd3bc4959188aea7e83f35d78c6a6068bb8633f8`. Includes upstream memory-hook
  preservation/review changes through `4b8ee4e`; no other instance modified.
- Full Rails run: 2,232 tests, zero assertion failures, one Vite missing-manifest
  error in ChatFlowTest. After assets were available, the integrated rerun of
  that entire test class, command/redaction/ingestion/reporter tests and
  memory-hook tests passed: **37 tests / 266 assertions**. No test was disabled.
  **20 browser journeys** and **82 frontend unit tests** passed.
- The final Rails image was tested directly for useful preview preservation and
  credential redaction before deployment. Normal Kamal deploy succeeded with
  automatic fleet reconciliation held until after the canary.
- A full resident backup was refused because a resident was busy; it was not
  interrupted. A fresh database-only backup succeeded:
  `souls_house_production_2026-09-06_15-43-34.sql.gz`. This is not a claim of a
  fresh complete resident backup set; the earlier successful full backups remain.
  No schema changes or resident-volume replacement were required.
- Previous runtime retained as
  `helixkit-agent-runtime:pre-useful-previews-20260906`,
  image `sha256:9a7f98b937277aa825f803b4653098ee889c70501ac404828c6292aeb2c8cd07`.
- Production synthetic canary passed through the installed shim, HTTPS callback,
  database projection and reply helper. Live and historical labels retained
  `grep -n runtime app/services/agent_dispatch.rb`; the credential-bearing
  command became `curl -H [REDACTED] https://example.test`. Private canary text
  was absent from public activity. Eight events, one correlated reply, completed
  card retained; 64 KiB/no-redirect callback check passed. No model was invoked;
  synthetic records and container were removed.
- All nine residents were idle by rollout time and verified healthy on runtime
  `sha256:e79ceb9abdfd1f46d3e9e24f8dcfb568da00484328b0131d11cd1be28683a435`.
  No deferred residents remained. Final public health HTTP 200, Mnemodyne
  readiness passed, zero failed queue executions in the preceding 15 minutes.
- Detailed evidence remains in this instance's ignored
  `log/preview-redaction-*.log` files. This subsequent documentation commit is
  not the deployed application release identity.
