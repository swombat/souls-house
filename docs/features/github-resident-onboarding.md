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
   for import; standard two-way sync and an existing script that pushes also need
   Contents write access.
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
current house-managed runtime image. Repository approval does not pin the
house's image or require reapproval for ordinary house runtime updates.
Obtain those names from the resident's hosting resources;
never substitute a sibling's or a development volume. Open Chaos interactively
with its entrypoint overridden, the identity mounted at its canonical
`/home/agent/identity`, and the Chaos volume at `/home/agent/.chaos`. Do not run the
ordinary container entrypoint merely to reach the trust screen.

Before starting, prepare a temporary mode-0600 environment file from the
request/resident's Rails records. It must contain only:

- `SOULSHOUSE_APP_URL`: the house URL reachable from the maintenance container.
- `SOULSHOUSE_BEARER_TOKEN`: this resident's outbound house API token.
- `SOULSHOUSE_GITHUB_IMPORT_ID`: the import's internal ID.
- `SOULSHOUSE_GITHUB_IMPORT_FINGERPRINT`: its full approved credential fingerprint.
- `SOULSHOUSE_GITHUB_IMPORT_REPOSITORY` and `SOULSHOUSE_GITHUB_IMPORT_BRANCH`.
- `SOULSHOUSE_PORTABLE_HOME_ID`: the reviewed identity ID.
- `SOULSHOUSE_HOME_SYNC_STRATEGY`: the request's reviewed `sync_strategy`
  (`existing` or `standard`).
- `SOULSHOUSE_HOME_SYNC_CONFIGURATION`: JSON encoding of the request's immutable
  reviewed `sync_configuration`, including `auto_commit_paths`,
  `append_only_paths` and `allow_destructive_paths` for standard sync.

Derive these sync values from the same approved request/resident records used
for bootstrap, not by rereading the branch's current manifest or inventing a
fresh local policy. Preserve the reviewed JSON and literal scopes exactly.
Standard import approval checks this policy; missing or mismatched values fail
closed, even if the new manifest would otherwise validate.

Do not include a GitHub token, provider credentials or another resident's token.
Do not print the file or place it in Git. These are the same approval-context
fields used by normal hosted bootstrap. The helper **requires a live approval
check before it opens Chaos**, since accepting trust can start project-configured
commands such as MCP servers. It removes the house bearer from Chaos's environment
after checking. Missing, revoked or changed approval fails closed.

For example, with the resource names, private environment-file path and a Docker
network that can reach the house set by the operator:

```sh
docker run --rm -it --network "$HOUSE_NETWORK" --env-file "$APPROVAL_ENV_FILE" \
  -e HOME=/home/agent -e TERM=xterm-256color \
  -v "$IDENTITY_VOLUME:/home/agent/identity" \
  -v "$CHAOS_VOLUME:/home/agent/.chaos" \
  --entrypoint /usr/local/bin/github-import-trust-setup "$HOUSE_RUNTIME_IMAGE"
```

Review and accept the trust screen for that exact canonical root, then exit
without submitting a model prompt. No provider or GitHub credentials are needed
in this maintenance container. Remove the temporary environment file after the
trust steps. The helper prepares the runtime home using the
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
and remain inside the repository. With **Keep existing sync** (the default), the
sync entry point must be a Python file. **Use standard two-way Git sync** permits
the manifest to omit `sync`; it uses the house's standalone runner instead.
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

## Choose and review the sync policy

The import form offers **Keep existing sync** and **Use standard two-way Git
sync**. Existing sync leaves the reviewed home's own script responsible for its
policy. This choice does not enroll or modify an existing resident.

Standard sync exchanges committed changes with the selected branch on `origin`.
It does not save arbitrary uncommitted work. To opt into automatic commits,
declare literal repository-relative file or directory scopes in the manifest:

```json
{
  "standard_sync": {
    "auto_commit_paths": ["journals", "notes"],
    "append_only_paths": ["journals"],
    "allow_destructive_paths": []
  }
}
```

An absent or empty `auto_commit_paths` list means **committed changes only**:
uncommitted edits are not automatically saved. Never include credentials,
host-local state or unreviewed identity anchors. Append-only and destructive
allowance scopes must be inside the eligible auto-commit scopes. The request
shows the exact immutable policy taken from the reviewed manifest before
approval; there is no browser path editor.

All auto-commit paths are protected: deletion, or shrink below 50% of HEAD byte
size, is refused without an explicit destructive allowance. This also checks
incoming committed changes, not only uncommitted local edits. Append-only paths
always refuse rewriting or truncation, even with an allowance. Append-only
merging requires an exact common-base complete UTF-8 line prefix. Each appended
suffix remains verbatim, including multiline order, repeated lines and blanks.
Equal suffixes are deduplicated as whole blocks. If one entire suffix is a prefix
of the other, only the longer remains; genuinely divergent suffixes are
concatenated as whole blocks in UTF-8 byte lexicographic order. Individual lines
are never sorted or deduplicated. This is not general conflict resolution or a
guarantee of chronological ordering between concurrent hosts.

Staged changes, edits outside the eligible policy, an existing Git operation,
or the wrong branch stop a cycle for manual review. Ignored or untracked files
that integration would overwrite cause an explicit refusal and remain intact.
On conflict or integration
failure, the runner aborts integration, preserves local commits and attempts a
non-force push of local HEAD to a unique `rescue/<host>/<UTCtimestamp>-<random>`
ref. A rescue push is **not** successful sync of the selected branch. If rescue
fails, keep the local copy; do not discard it, overwrite another host or
force-push. Preserve both sides and reconcile deliberately before retrying.
Rescue refs contain committed HEAD only, never ignored files or uncommitted
private data. A rejected push to the selected branch is a failure, not sync
success.

### Read sync health honestly

The import page displays a cached runtime health check, not a live Git query:
last confirmed success, its reported age, report time and any rescue
outcome. `unknown` and `stale` do not mean up to date. `busy`, `blocked`, `failed`
and `needs_attention` do not advance the last-success timestamp. Protected
refusals and conflicts need attention; rescue success and rescue failure are
reported separately, neither as branch-sync success. Even a successful check
does not prove every other host has synchronized or that external memory works.
No raw Git output, private contents or arbitrary runner error is displayed.
Age is calculated when the page is presented, not a ticking browser clock.
A formerly successful report becomes stale after 30 minutes without confirmed
success, or when its success timestamp is missing.

## Keep using the identity locally

Keep independent working copies on each host. The house is an additional home,
not a transfer that shuts down the laptop:

```sh
git clone git@github.com:example-org/example-home.git
cd example-home
export SOULSHOUSE_HOME_ROOT="$PWD"
```

### Run standard sync locally

The same standalone runner can be used outside the hosted runtime. It needs
Python 3.9+ on Linux or macOS, Git, a checkout on the selected branch with no
staged changes or unfinished Git operation, and your own working
`origin` credentials (Contents write permission for GitHub pushes). It contains
no credentials and installs no scheduler or cross-harness adapter.
Automatic commits use `Home sync <home-sync@localhost>` unless configured
otherwise; installing a personal Git author is not a prerequisite.

Install the pinned runner outside the identity repository, verify its checksum,
then run it against the existing local checkout:

```sh
# Pinned implementation revision and checksum are recorded with this release.
SYNC_COMMIT=655012e86f710c02f7ea79fabc8e39e02103801d
SYNC_SHA256=4fe8b1d5849a63699ab43e5194d4e0d2443129d3970b5adf364992d282f22479
SYNC_FILE="$HOME/.local/share/souls-house/standard_home_sync.py"
mkdir -p "$(dirname "$SYNC_FILE")"
curl --fail --location \
  "https://raw.githubusercontent.com/swombat/souls-house/$SYNC_COMMIT/agent-runtime/standard_home_sync.py" \
  --output "$SYNC_FILE"
printf '%s  %s\n' "$SYNC_SHA256" "$SYNC_FILE" | shasum -a 256 -c - &&
  python3 "$SYNC_FILE" --root "$SOULSHOUSE_HOME_ROOT" --branch main
```

That default syncs **committed changes only**. For the example policy above,
replace the final invocation with:

```sh
python3 "$SYNC_FILE" --root "$SOULSHOUSE_HOME_ROOT" --branch main \
  --auto-commit-path journals --auto-commit-path notes \
  --append-only-path journals
```

Repeat `--auto-commit-path`, `--append-only-path` and, only for explicitly reviewed
exceptions, `--allow-destructive-path` as needed to match the manifest's policy.
Choose the real selected branch, not necessarily `main`. Only `origin` is used;
the command does not discover arbitrary remotes or configure authentication.
Keep the runner file pinned and verified when wiring this command into your
local harness's supported hooks or scheduler. That wiring is your separate
local setup, not performed by import or by this command. Review output and
manual failure guidance before scheduling repeated cycles.

The common Git directory holds `standard-home-sync-status.json` and
`standard-home-sync.lock`, outside the versioned home. The advisory lock
coordinates this runner only: keep other Git operations and editors quiescent
while a cycle runs. Do not delete a held lock to bypass another cycle. Hosted
standard sync checks every ten minutes; local scheduling remains separate.

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
