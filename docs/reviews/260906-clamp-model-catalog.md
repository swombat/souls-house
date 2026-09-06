# Subscription bridge model-catalog diagnostics

## Cause

Hosted Anthropic subscription turns run with `clamp=true` through Claude Code.
Hosted Gemini subscription turns run with `clamp=true` and
`clamp_backend=antigravity`. Their credentials belong to those first-party
CLIs; the shim deliberately removes native API keys from these invocations.

The pinned Chaos process table nevertheless constructs a normal native
`ModelsManager`. Its startup/list refreshes attempt native provider credentials.
Anthropic metadata lookups additionally refresh on demand, so one invocation
can repeat the same diagnostic several times.

OpenAI and xAI subscription turns instead use Chaos's native account support,
which explains why Wing and Grok do not have this particular mismatch.
These catalogue errors alone do not establish that the inference login failed.

## Runtime patch

`agent-runtime/patches/chaos-clamp-cached-catalog.patch` makes a manager created
for startup clamp mode use the existing offline/cache refresh strategy. Empty
caches remain empty; fresh cached metadata and explicitly supplied catalogues
remain usable. No catalogue or credentials are invented.

Normal native/API-key runs retain live catalogue discovery and its error
reporting. Provider rebinding preserves the discovery policy. Nothing filters
STDERR, changes logging severity, or suppresses errors from Claude Code or
Antigravity themselves.

The Docker build applies/checks the patch against the existing pinned Chaos
commit `f3bb63d6aec1ffdcab6330095701f3308c350199`, alongside the two existing
Antigravity patches. No other development checkout was edited.

This is scoped to the hosted startup/headless clamp configuration. It does not
attempt to redesign interactive `/clamp` toggling or obtain live catalogues from
the two CLI bridges.

## Verification

- Rust code compiled against the pinned source in an instance-local source tree.
- Model-manager unit suite: **21 passed**, including both providers with absent
  native credentials, empty and populated caches, provider rebinding, and the
  native-path failure that must remain visible.
- Hosted shim/session tests: **59 tests / 430 assertions**, no failures/errors.
- All three runtime patches apply together; patched manager/process-table files
  match the locally compiled source.

Not deployed. Shipping this requires rebuilding the hosted runtime and safely
reconciling affected residents while idle. Merely deploying Rails cannot change
the Chaos executable in already-running resident containers. Historical STDERR
records should remain unchanged.
