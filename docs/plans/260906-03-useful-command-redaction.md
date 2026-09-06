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
