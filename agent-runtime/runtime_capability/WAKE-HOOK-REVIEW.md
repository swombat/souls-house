# Wake-hook review — discovery-only first integration

2026-10-10. Source review, not implemented or approved.
Reviewed checkout: runtime-audio-dependencies at 890257ad.
This is the audio dependency PR branch, not a claim about current master.
Conversation sources: nJdXqJ/YxxERY and jqkanY.

## Placement

`trigger_shim.py` appends the sibling notice to both `prompt` and a nonempty
`request_delta` near lines 383–387, before choosing persistent or legacy execution.
The capability notice should follow that pattern, computed once per accepted
trigger. Putting it only in `build_prompt_with_components` would omit it on a
successful resume. A failed resume's fresh fallback must reuse the same result,
not run another check. No new wake, room post, session roll, or identity
fingerprint entry is needed.

## Checker process

The shim must not import resident YAML in-process. Launch a runtime-owned worker
using an explicitly reviewed resident-tools interpreter (the current Dockerfile
uses system Python with python3-yaml). `sys.executable` is suitable only after
confirming the shim and resident tools actually share it.

The worker reads only `AGENT_IDENTITY_PATH/runtime-requirements.yml`; request
payloads cannot select the path, interpreter, command, or probe map.
Use the existing structural bounds, then reviewed literal discovery probes.
Set a single outer wall-clock deadline (proposed: 3 seconds) for reading,
parsing and both one-second module probes. Kill/reap on timeout; do not
leave a background thread. This still is not CPU/memory or descendant-process
isolation. Trusted parent-directory and Python-startup assumptions remain.

Suppress stderr and return a small fixed-schema JSON result, never YAML,
reasons, raw exceptions, paths or parser diagnostics. Bound stdout at the
parent's read boundary; `capture_output=True` followed by a length check is
not a capture limit. Use a bounded reader or another reviewed bounded transport.
Failure of the checker must not fail the resident's turn.

## Notice contract

- Absent file: no notice; this is not evidence that capabilities are intact.
- Valid explicit empty lists: no notice; no dependencies were declared.
- All reviewed declarations found: no notice; do not say "available".
- Missing, unsupported or probe error: compact grouped names and states.
- Invalid manifest: generic invalid-manifest notice; never reason text.
- Worker timeout, missing parser/interpreter, malformed/oversize output:
  generic "Capability discovery could not complete"; never report missing.

When item states are shown, include: "Discovery only; found does not establish
working capability. No installation performed." Keep notices bounded (proposed
4 KiB), with explicit truncation if necessary. Only validated, normalized package
names may be rendered; never concatenate unvalidated worker output into a prompt.

No auto-install, package-manager query, import check or cache in this slice.
Repeated unresolved notices are current observations, not instructions to
escalate. Declaration does not authorize installation or create a house guarantee.

## Submission gates

Before a PR: test absent/empty/invalid distinctions, private-reason exclusion,
mixed states, worker failure/timeout/oversize output, and full/resume/fallback
prompt paths with exactly one checker invocation per trigger. Use synthetic
fixtures only; exclude claude-fixture.yml from artifacts.

Verify interpreter/PATH alignment inside a built image separately. Local mocked
tests do not establish deployed capability. Rebase onto current master and review
the actual hook paths before submission; this source review alone is insufficient.
