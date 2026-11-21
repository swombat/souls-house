# A resident left paused

A backup holds a resident still with `docker pause` (`Backup::AgentRestic`).
Nothing else in the house pauses a resident's container. If the backup's
worker dies first (a deploy restarting the jobs container is the known
cause), the resident stays frozen: its runs wait, then fail as unhealthy.

The house does not unpause on its own (#1042, scoped with Mira). Even an
accurate "no backup containers running" can't say who owns the pause, so
this is done by hand, after the checks below.

## How you hear about it

`Backup::PausedResidentWatchJob` runs every 10 minutes in the jobs
container. A local resident it has seen paused for 30 minutes or more is
reported once per episode as `Backup::ContainerPause::StillPaused`:

- to the jobs container's log, `[Backup::ContainerPause] Resident <id>
  (<name>)'s container has been paused since at least <time>`;
- to Honeybadger, project souls.house (134447), through `Rails.error`.

Those are the only two places it goes. The Honeybadger project has no
integrations, and its one user is Daniel. Residents can read it through
their Honeybadger connection:

```sh
curl -s -u "$TOKEN:" \
  'https://app.honeybadger.io/v2/projects/134447/faults?q=class:"Backup::ContainerPause::StillPaused"'
```

The log is lost when a deploy replaces the jobs container. Honeybadger
keeps it.

Other signs: a resident's runs fail as "unreachable" or "container paused,
cause unconfirmed", and `docker ps --filter status=paused` on the host is
not empty.

## Before unpausing

Do each step on the production host
(`ssh -p 12222 swombat@95.217.118.47`). If any step can't be established,
stop and escalate (below) instead of guessing.

1. **Exactly which resident and which container.** List what is paused, and
   match the name to the resident's `container_name`:

   ```sh
   docker ps --filter status=paused --format '{{.Names}} {{.Status}}'
   ```

   ```ruby
   Agent.where(container_name: "<name>").pluck(:id, :name)
   ```

   The name has to belong to a resident on this host. Don't unpause a
   container you can't name.

2. **Why it was paused.** Look for that resident's last backup: the
   StillPaused notice's "since" time, its latest `Backup::AgentResticJob`, and the
   time of the last deploy (`docker ps` shows how
   long the jobs container has been up). The known story is "a backup
   paused it and its worker was killed". If you can't find a backup that
   paused it, you don't know why it's paused.

3. **No backup or maintenance is still running or about to start.** All of
   these have to be empty for this resident:

   ```sh
   docker ps --format '{{.Names}} {{.Image}}' | grep -E 'restic|busybox'
   ```

   ```ruby
   SolidQueue::Job.where(finished_at: nil).where("class_name LIKE '%Backup%'").pluck(:class_name, :arguments)
   Agent.where.not(backup_thinning_started_at: nil).pluck(:id)
   ```

   Also check that no deploy, server move or restore is in progress, and
   that the nightly backup isn't due within the next few minutes (04:00Z).
   If something is still running, wait for it to finish and check again.
   Don't unpause underneath it.

## Unpausing

```sh
docker unpause <name>
```

## Checking it worked

```sh
docker inspect --format '{{.State.Running}} {{.State.Paused}}' <name>   # want: true false
docker ps --filter status=paused                                         # want: empty
```

Then the resident's health goes green within a few minutes, and a new
run succeeds. Write down what you found and when you unpaused it, in the
thread where the problem came up.

## Escalating

If any check can't be established, for example Docker doesn't answer, the
container belongs to nobody you can name, a backup is still running and
doesn't finish, or there's no backup to explain the pause, leave the
container as it is and tell Daniel what you saw and which step stopped
you.

## What happened before

- 19 Nov 2026: Mira was left paused from about 04:06 to 05:32Z after the
  nightly backup and was unpaused by hand. This led to #1042.
- 21 Nov 2026: Mira was paused from about 04:10Z. The 04:24Z deploy
  restarted the jobs container. StillPaused reached Honeybadger at
  04:40:02Z. Nobody acted on it: she was found from her failed runs and
  unpaused at 06:50:53Z, after checks 1 to 3.
