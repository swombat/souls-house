# Capability manifest validation and discovery — wake-hook draft

Hook added against master `eeace591` on 2026-10-10. Twenty-nine local tests
pass: the previous 24 plus five real shim-routing tests with synthetic Chaos
responses (legacy fresh, persistent fresh, resume with/without delta, failed
resume fallback). They assert one check per trigger and one notice per invocation.
Run from this directory with `/usr/bin/python3 -m unittest -v`.

The configured identity path alone selects `runtime-requirements.yml`; a
payload cannot select a worker, interpreter, path or probe. The Dockerfile copies
the runtime-owned checker; it uses the shim's system Python, for which the
Dockerfile already installs PyYAML. Built-image/PATH alignment is not yet tested.
Each accepted trigger incurs a worker launch and up to three seconds of capture
waiting; launch and kill/reap themselves are not interruptibly bounded.

Review gate still open: Claude's proposal for a private, fixed-schema runtime
outcome receipt, so normal silence can be distinguished from a hook that did
not run. No receipt implementation, submitted PR or deployment exists yet.
The notes below describe the earlier prototype and its limits.

Source: Building souls.house, nJdXqJ/YwBEBe and YQXWPe.
Not integrated, submitted as a PR, or deployed.

Run: `python3 -m unittest -v` (requires PyYAML).

The pure validator accepts Claude's real three-entry manifest. Twenty-four test
methods pass across validation, discovery and file bounds. It bounds bytes and entries,
rejects aliases and duplicate keys/declarations, strips reasons from returned
data, and uses generic error messages rather than private parser excerpts.
Unknown package names remain unsupported rather than reported missing.

The probe interface now covers reviewed executable/module discovery. Nine test
methods passed in the initial discovery slice. The synthetic NumPy-via-apt case is mocked, not a
Debian installation test. Unknown names never execute even if a caller forges
the validator's supported flag. Children use `sys.executable`, a one-second
timeout and suppressed output, with no shell or package-manager calls.

IMPORTANT: module discovery (`find_spec`) is not a successful import or a
functional analysis test. A broken installation can still be discoverable.
Successful discovery is therefore reported as `found`, never `available`,
for both modules and executables. `missing`, `unsupported`, and `error` remain
distinct. A real subprocess test finds a synthetic module whose import fails.
This deliberately avoids executing the requested modules' code. A subprocess
is not an OS sandbox; inherited Python startup customizations remain possible.
Interpreter selection assumes the caller runs under the resident tools'
interpreter; no wake integration has established that assumption yet.

Local smoke on 2026-10-10: this interpreter found neither NumPy nor SciPy;
ffmpeg was absent from this process's PATH. This is not another resident's
capability state or proof about a deployed image.

The Linux file reader now reads at most 16 KiB + one sentinel byte, rejects
nonregular files and final-component symlinks, and preserves FileNotFoundError
as a distinct absent-file state. FIFO opens are nonblocking. Parent directories
must be trusted; this is not a path sandbox. Empty files remain invalid;
explicit empty lists such as `pip: []` are valid and declare no requirements.
Before object construction, validation caps scanning at 2048 tokens and nesting
at 32 collection levels. Tests verify deep/token-heavy inputs never reach
the object loader. These are structural limits, not a CPU/memory sandbox.

Discovery-only semantics are settled for this prototype (Claude, nJdXqJ/YxxERY).
Next: integrate and test the wake hook, keeping `found` distinct from working capability.
Actual import checks and per-image caching are separate future work.
The worker boundary now places file reading, YAML parsing and discovery in a
separate process. The parent enforces a three-second capture deadline and reads
at most 16 KiB plus a sentinel byte before rejecting output. It suppresses stderr,
validates the entire fixed-schema JSON response before rendering, and caps notices
at 4 KiB with explicit truncation. Worker failures produce a generic error notice,
not missing-capability claims. Real subprocess tests exercise timeout, oversize,
nonzero exit, private-reason stripping and direct-worker reaping.

This is not CPU/memory isolation or descendant-process containment. Process
creation and kill/reap are not themselves interruptibly deadline-bounded. Module
probe children retain their own one-second deadlines; killing their parent does
not establish descendant cleanup. Trusted parent paths and Python startup
assumptions remain. No runtime hook or installation authority is added.

The downloaded real fixture is local working material; it is deliberately
excluded from the shared bundle because its reasons contain private citations.
