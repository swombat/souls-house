# GitHub deployment buttons

Four manual Actions deploy **Rails**, **Chaos**, **both** (Rails first), or
**Rebuild residents**. Select `master`, press **Run workflow**.

**Rebuild residents** (`runtime`) rebuilds resident images from souls-house
master but keeps the Chaos revision the residents already run, read from the
`house.souls.chaos-ref` label of each resident's current image. Use it to ship
`agent-runtime/` changes (helpers, hooks, entrypoint) without adopting an
unreviewed Chaos release. It never asks upstream for a newer build. It refuses
when residents run different revisions, and it refuses before restarting anyone
if the rebuilt `chaos --version` differs from any running one. **Update Chaos**
remains the only button that moves Chaos, always to the newest published
mainline build; it does not read `agent-runtime/chaos-ref`. No home computer or additional approval
is needed. The host resolves latest master / latest published mainline Chaos
once and records exact revisions. A green result means verification completed,
not merely that the request was accepted.

Only the `swombat` GitHub account may execute deployments. The shared transport
checks both the original caller (`github.actor`) and the current attempt's
caller (`github.triggering_actor`) before the environment-backed job starts.
Other repository writers can still see and dispatch workflows, but their
deployment job is skipped without receiving credentials. They cannot deploy by
rerunning a previous owner-authorized run either. Use a fresh owner dispatch
rather than rerunning another person's rejected request.

This is an execution guard, not protection against malicious changes merged to
`master`: repository administrators and reviewed mainline workflow code remain
trusted. Keep the master-only environment policy and protected-mainline review
rules in place. Older workflow runs retain their old definition when rerun;
disable reruns of pre-guard deployment runs by deleting those Actions runs
(retain host-side deployment receipts).

The Chaos build channel includes upstream's `build-<sha>` prereleases. The
version-tagged “latest stable” release can be older than the installed runtime.
We require published Linux artifacts on upstream master, verify their checksum
and embedded source revision, and never compile as a fallback. A same-source
checksum verifies download integrity, not publisher independence. GitHub and
upstream release authority remain trusted. Existing SQL migration edits or
removals, divergent history, unknown custom images, or a downgrade require an
operator; this worker does not invent a state migration.
Migration checks compare complete recursive Git trees, rejecting a truncated
tree. They do not rely on GitHub compare's 300-file changed-file limit.

## From inside the app

**Site Admin → Deploy** (`/admin/deploys`) offers the same four buttons. Each
press dispatches the matching `workflow_dispatch` workflow on `master` through
the GitHub API, writes an audit log entry, and follows the run until it
finishes. It uses `credentials.github.deploy_token`, a fine-grained PAT owned by
the deploying account, scoped to this repository only, with **Actions: read and
write** and nothing else. Because the token is that account's, the workflow's
actor check passes, so the token is that account's hand. A site-admin session
can choose *when*, never *what*: the workflows only build `master`. The page
reads the repository from `HOUSE_SOURCE_REPO` (set it in `config/house.env` for
a fork) and warns when GitHub reports the token expiring within 14 days.
Credentials load when the app starts: add the token, then deploy once the old way.

A fork must also replace the upstream login in `deploy-house.yml`'s two actor
checks with its own deploying account. See "Optional: deploy from inside the
app" in `public/self-host.md`.

## Authority and installation

See issue #144 and the scoped amendment to ADR 0002. Production secrets stay in
root-only `/etc/house-deploy/{house.env,secrets,settings.json,ssh/}`. The
`secrets` file is a deliberately provisioned Kamal secrets file, not extracted
from live containers. The internal Kamal SSH key is separate from the trigger
key. It reaches the deployment host from itself. The tools container uses host
Docker to build; it is not a GitHub runner.

After reviewing `ops/deploy/`, install on the host:

```sh
sudo ops/deploy/install
sudo docker build -t house-deploy-tools:1 ops/deploy
```

Provision `settings.example.json` with local installation values; copy the
installation's `config/house.env` and `.kamal/secrets` to the above root-only
paths. Keep the whole SSH directory root-only; provide its `id_ed25519`,
`known_hosts`, and optional `config`. Authorize the internal Kamal key on the
host SSH account, restricted to host-local source addresses where practical.
Never copy a person's general-purpose private key.

In the trigger account's **root-owned** `authorized_keys`, install exactly:

```text
restrict,command="/opt/house-deploy/ssh-command" ssh-ed25519 PUBLIC-TRIGGER-KEY
```

The trigger account must have no additional keys, password login, groups or
sudo rules. Its root-owned forced command exact-matches four verbs plus bounded
job-status lookup. The privileged gate repeats validation and starts one of
four fixed units. It accepts no shell, revision, image, path or unit name.
The account cannot write the wrapper, home, keys, config or status directory.
Root worker scripts are installed explicitly; deploying master does not silently
replace this privilege boundary. Review and reinstall it when changing it. Adding
the **Rebuild residents** button requires re-running `sudo ops/deploy/install`
once, which installs the new gate grammar and the `house-deploy-runtime` unit;
until then the button is refused at the forced command.

Configure GitHub environment **`production-deploy`**:

- **Deployment branches/tags: selected branches**, exactly branch `master`;
  no tag rule, no required reviewer, no wait timer.
- Secrets `HOUSE_DEPLOY_KEY` and `HOUSE_DEPLOY_KNOWN_HOSTS`.
- Variables `HOUSE_DEPLOY_HOST` and `HOUSE_DEPLOY_PORT`.
- **No repository-level copy** of the key. The environment policy, not a
  workflow `if`, stops a branch-modified workflow from reading the credential.
- Verify the SSH fingerprint against the existing trusted operator connection,
  not an unverified `ssh-keyscan` at deploy time.

Changing master or the environment is consequential authority: the app already
has Docker access. A restricted trigger is not protection against malicious
approved source or a compromised repository administrator.

## Completion, interruptions, and ordinary recovery

The host serializes requests. Same-operation requests attach to an active job;
different operations are rejected while it runs. GitHub serializes its own
buttons too. The detached systemd worker survives an SSH disconnect.
Status includes only operation, IDs, state, revisions and progress. Raw logs,
previous resident image/availability metadata and per-resident receipts stay in
`/var/lib/house-deploy/runs/<id>/`, root-only. No raw Kamal log is sent to Actions.
Reconnect with `ssh … "status <id>"`; a network error is not deployment success.

Rails uses Kamal's normal deploy lock, including against manual Mac/Dell deploys.
It skips automatic runtime-build/reconcile hooks, checks web/jobs revisions and
public `/up`, and refreshes Telegram webhooks separately.

Chaos retains previous images and original volumes, waits at most ten minutes
per busy resident, and restarts one resident at a time. The existing SQL admission
gate blocks enqueue/admission only for the short actual restart, so new requests
wait and are delivered afterwards instead of being cancelled by a visible pause.
PostgreSQL releases a gate idle in external Docker/HTTP work for90 seconds;
per-resident receipts record observed `gate_seconds`. This bounds a hung external
call, not a claim that every failure automatically restores a usable resident.
No model is invoked, private memory read, or full-volume snapshot made. Skipped
busy residents remain unchanged: final **partial** is red in Actions.

**Manual runtime operators must take the same host lock:**

```sh
sudo flock -n /var/lib/house-deploy/deployment.lock YOUR-REVIEWED-ROLLOUT-COMMAND
```

Never clear locks while a worker runs. Inspect the fixed units with
`systemctl status house-deploy-{rails,chaos,both,runtime}`. Stopping/cancelling GitHub does
not cancel the host deployment. Host timeout or restart produces `interrupted`,
not success. Failed and interrupted requests block further deployments.
Inspect resident/container state before clearing
`/var/lib/house-deploy/current.json` to allow another request.

A failed resident recreation is left inactive/paused for operator repair, with
its image reconciled to Docker's actual image when the container can be inspected. Its
previous image and flags are recorded before changes. Rolling back a binary
does not reverse a schema migration; do not automatically boot an older binary
against migrated state. Existing GitHub/restic backups remain the recovery
system. There is no automatic full-volume backup ceremony here.

## Tests

```sh
python3 -m unittest discover -s test -p host_deploy_test.py
bash -n ops/deploy/install
```

Tests use temporary directories and fake subprocesses, never production
credentials. Provisioning verification must also exercise a rejected command,
master-only secret policy and a real GitHub request through final health checks.
