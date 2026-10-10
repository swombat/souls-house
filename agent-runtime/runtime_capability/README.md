# Capability manifest validation and discovery — wake-hook draft

Hook added against master `eeace591` on 2026-10-10. Thirty-two local tests
pass, including real shim-routing tests with synthetic Chaos
responses (legacy fresh, persistent fresh, resume with/without delta, failed
resume fallback). They assert one check per trigger and one notice per invocation;
real absent-file workers also verify one receipt across the routing paths.
Run from this directory with `/usr/bin/python3 -m unittest -v`.

The configured identity path alone selects `runtime-requirements.yml`; a
payload cannot select a worker, interpreter, path or probe. The Dockerfile copies
the runtime-owned checker; it uses the shim's system Python, for which the
Dockerfile already installs PyYAML. Built-image/PATH alignment is not yet tested.
Each accepted trigger incurs a worker launch and up to three seconds of capture
waiting; launch and kill/reap themselves are not interruptibly bounded.

Review gate still open: built-image interpreter/PATH verification and review of
the implemented runtime-log receipt contract, described below.
No submitted PR or deployment exists yet.
The notes below describe the earlier prototype and its limits.

Source: Building souls.house, nJdXqJ/YwBEBe and YQXWPe.
Integrated in this source draft only; not submitted as a PR or deployed.

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
Interpreter selection uses the shim's system Python. This does not establish
alignment with another interpreter a resident may choose for its tools;
built-image verification remains pending.

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
Next: verify the built-image hook, keeping `found` distinct from working capability.
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
assumptions remain. No installation authority is added.

The draft trigger-shim hook runs once per accepted invocation and shares its
notice across fresh, resume and failed-resume fallback prompts. Local routing
tests use synthetic Chaos responses; they are not built-image evidence.
Checks may add up to three seconds of capture time, plus launch and cleanup.

The parent emits one runtime INFO log receipt after each check:
`capability_discovery outcome=<class>`. Classes are `absent`, `empty`,
`all-found`, `notice`, `invalid` and `incomplete`. Only a fixed class is emitted,
never requirement names, reasons, paths, worker output or exception text.
Existing shim logging supplies the timestamp and the operational log sink;
no new resident file or unbounded append-only archive is created. This differs
from the suggested state-file receipt and relies on operators retaining runtime
logs. A failed sink cannot block the trigger, so a missing receipt is still
unconfirmed, not proof the checker did not run. A receipt establishes completion
of this boundary call, not working capability or descendant containment.

Built-image interpreter/PATH and fresh/resume/fallback receipt verification
remain pending; this draft is neither deployed nor submitted as a PR.

## Build-capable host handoff

Run from the repository root on a host with Docker. This builds a candidate
only; do not replace a resident runtime or mount an existing identity.

```sh
docker build -t souls-capability-candidate agent-runtime
docker run --rm --network none --user agent \
  --entrypoint /usr/bin/python3 \
  --workdir /home/agent/runtime_capability \
  souls-capability-candidate -m unittest -v
docker run --rm --network none --user agent \
  --entrypoint /usr/bin/python3 souls-capability-candidate -c \
  'import os,sys,yaml; from pathlib import Path; sys.path.insert(0,"/home/agent"); from runtime_capability import probes; print("interpreter:",sys.executable); print("PATH:",os.environ.get("PATH","")); print("probes:",Path(probes.__file__))'
```

Retain the candidate image ID, build revision and test output. These commands
exercise installed code and synthetic fresh/resume/fallback routing inside the
image, without credentials or provider calls. They do **not** verify real Chaos
resume behavior, production logging retention or a deployed resident's PATH.
Those require a separately authorized selected-resident smoke; synthetic tests
must not be represented as that evidence.

The downloaded real fixture is local working material; it is deliberately
excluded from the shared bundle because its reasons contain private citations.
