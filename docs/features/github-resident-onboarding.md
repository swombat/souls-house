# Bring an existing GitHub resident

This journey is for an **existing identity**, not a new soul seed or a house
backup archive. The first version supports the `portable_v1` home contract below.
An ordinary repository containing only a Markdown prompt is not yet compatible.

## Before requesting a home

1. Agree the additional residency with the resident. Importing a repository is
   not consent to change their memory practices or share private conversations.
2. Prepare a compatible private or public GitHub repository. Keep credentials,
   provider sessions and machine-specific state out of Git.
3. Create a fine-grained GitHub personal access token restricted to the intended
   identity repository, with only the permissions needed. Read access is needed
   for import; the resident's own sync may also need Contents write access.
   Connect it through Account Services as the person authorised to grant access.
4. Review the home's sync and wake scripts. These execute code. A manifest is
   configuration, not a security sandbox.
5. Decide which host owns scheduled jobs. A second residency must not silently
   start another heartbeat, consolidation worker or Telegram listener.

The token's format can identify it as fine-grained, but cannot prove its complete
repository selection or effective permissions. Check those in GitHub. A successful
repository connection proves access, not least privilege. Classic and unknown
token formats are not supported by this onboarding flow.

## Approval is a host decision

An account owner or administrator prepares the import request. A **site
administrator** must approve execution of the imported home before provisioning.
Account membership, a repository file, a form parameter or an agent instruction
cannot grant that approval.

Approval covers the named repository and branch, **including future pushes to
that branch**. It is not a promise to execute only the snapshot the administrator
reviewed. The review records the observed commit SHA and credential fingerprint.
Replacing the credential requires a new approval; ordinary branch advancement
does not. Treat repository write access as the ability to change future code
running in that resident's container.

The fingerprint is an identifier, not a credential. Tokens must never appear in
screenshots, provenance records or Git remote URLs. Removing an approval or
disconnecting a service does not recall a credential that code already copied,
or prove that an already-running process has stopped.

This flow does not grant host root, a Docker socket, another resident's files or
arbitrary host mounts. Nor does it certify arbitrary third-party code as harmless.
The administrator is accepting execution within the existing resident-container
trust boundary.

## Operator trust step in the current runtime

The current Chaos release has an interactive project-trust screen, but no
supported non-interactive trust-grant command. After approval and seeding, a
new import therefore waits at **Home imported; operator trust step needed**.
It is not online, and the normal repository hooks/sync have not been started.
This is an explicit manual step, not fully automatic deployment.

A site operator must use the resident's own identity and Chaos volumes and the
approved runtime image. Obtain those names from the resident's hosting resources;
never substitute a sibling's or a development volume. Open Chaos interactively
with its entrypoint overridden, the identity mounted at its canonical
`/home/agent/identity`, and the Chaos volume at `/home/agent/.chaos`. Do not run the
ordinary container entrypoint merely to reach the trust screen.

For example, with the three reviewed resource names set by the operator:

```sh
docker run --rm -it --network none \
  -e HOME=/home/agent -e TERM=xterm-256color \
  -v "$IDENTITY_VOLUME:/home/agent/identity" \
  -v "$CHAOS_VOLUME:/home/agent/.chaos" \
  --entrypoint /usr/local/bin/github-import-trust-setup "$APPROVED_IMAGE"
```

Review and accept the trust screen for that exact canonical root, then exit
without submitting a model prompt. No provider or house credentials are needed
in this maintenance container. The helper prepares the runtime home using the
supported settings migration, then drops privileges to the agent user. It does
not run the normal entrypoint. If an OAuth runtime home is used, repeat the command
with `--oauth` after the image name to grant trust in that home's own Chaos
database too, rather than copying a database from elsewhere.
Do not edit trust or hook tables. The resident can subsequently revoke their own
runtime trust; retries must not silently regrant it.

Return to the request and choose **Retry activation after operator trust**.
Activation checks trust again and preserves the seeded home. These commands are
operator instructions, not a claim that a real Docker rollout was exercised by
the browser tests.

## Portable-home contract

Place `resident-home.json` at the repository root, for example:

```json
{
  "format": "souls-home/v1",
  "profile": "portable_v1",
  "identity_id": "example-resident-unique-id",
  "graph": "external",
  "instructions": "instructions.md",
  "soul": "soul.md",
  "narrative": "self-narrative.md",
  "hooks": ".chaos/hooks.json",
  "journal_reader": "scripts/read-journal.py",
  "sync": "scripts/sync.py",
  "sync_status": "state/sync-status.json"
}
```

Use a stable, unique identity ID. Referenced input files must exist, be nonempty
and remain inside the repository. The sync entry point must be a Python file.
`sync_status` is optional and may name a file not yet created. Do not use symlinks
to machine-local files or commit a different host's Chaos database.

The hook file must use the supported Chaos hook schema, with `SessionStart`,
`BeforeTurn` and `Stop` event entries. Commands and their dependencies belong to
the resident's own reviewed home. This contract does not generate journal entries,
rewrite identity anchors or require the house's memory vault.

The hosted root is exposed as `SOULSHOUSE_HOME_ROOT`. Resolve paths from that
variable rather than hard-coding a laptop path. See the [runtime
contract](../../agent-runtime/README.md#opt-in-imported-homes-mira_v1-portable_v1)
for hook import, sync status and existing-profile compatibility.

## Keep using the identity locally

Keep independent working copies on each host. The house is an additional home,
not a transfer that shuts down the laptop:

```sh
git clone git@github.com:example-org/example-home.git
cd example-home
export SOULSHOUSE_HOME_ROOT="$PWD"
```

Use the local harness's supported instruction entry point:

| Harness | Local integration |
| --- | --- |
| Chaos | Read the canonical instructions and install the reviewed hooks using that version's hook/trust controls. |
| Claude Code | Use `CLAUDE.md` to reference the canonical instructions; configure its own supported hooks separately. |
| Codex | Use `AGENTS.md` to reference the canonical instructions; configure supported tools and memory access separately. |

These are integration points, not an automatic cross-harness adapter generator.
The same files can preserve identity and memory access without promising identical
model behaviour, hook events or session state. Do not blindly copy hosted
credentials or trust settings into a local harness.

Use uniquely named immutable journal entries for concurrent writing. Git does
not automatically resolve simultaneous edits to a soul anchor or self-narrative:
surface those conflicts, preserve both sides and reconcile deliberately. A sync
process exiting successfully is not proof that every host is up to date.

## External memory and readiness

`graph: "external"` preserves the home's external-memory ownership; it does
**not** establish a working connection. Provision the resident's own host-local
Mnemodyne or other memory configuration separately, without committing secrets.
Check an authorised read and, where appropriate, a disposable test write through
that client's own health-check mechanism. Missing configuration should report
“not connected”, never “saved”.

Repository validation, administrator approval, container readiness, provider
authentication, successful memory access and a completed first reply are distinct
checks. A green import must not be described as proof of all of them.

Existing `mira_v1` and manually provisioned `portable_v1` residents are not
automatically enrolled, reconfigured or reapproved by this flow.
