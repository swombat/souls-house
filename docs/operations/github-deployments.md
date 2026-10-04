# GitHub deployment buttons

Three manual Actions deploy **Rails**, **Chaos**, or **both** (Rails first).
Select `master`, press **Run workflow**. No home computer or additional approval
is needed. The host resolves latest master / latest published mainline Chaos
once and records exact revisions. A green result means verification completed,
not merely that the request was accepted.

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
sudo rules. Its root-owned forced command exact-matches three verbs plus bounded
job-status lookup. The privileged gate repeats validation and starts one of
three fixed units. It accepts no shell, revision, image, path or unit name.
The account cannot write the wrapper, home, keys, config or status directory.
Root worker scripts are installed explicitly; deploying master does not silently
replace this privilege boundary. Review and reinstall it when changing it.

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
three buttons too. The detached systemd worker survives an SSH disconnect.
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
`systemctl status house-deploy-{rails,chaos,both}`. Stopping/cancelling GitHub does
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
