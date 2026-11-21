# A resident left paused

A backup holds a resident still with `docker pause` (`Backup::AgentRestic`).
A resident whose container stays paused is frozen: its runs wait, then fail
as unhealthy. One known cause is a backup worker killed while it held the
pause, for example by a deploy restarting the jobs container. It is not the
only possible owner of a pause, and matching times are a clue, not proof.

The house does not unpause on its own (#1042). Even an accurate "no backup
containers running" can't say who owns the pause, so recovery is manual and
follows the checks below. If any check can't be established, stop and
escalate instead of guessing.

## How you hear about it

`Backup::PausedResidentWatchJob` runs every 10 minutes in the jobs
container. A local resident it has seen paused for 30 minutes or more is
reported once per episode as `Backup::ContainerPause::StillPaused`, to the
jobs container's log and through `Rails.error` to the house's error
monitoring. The log does not survive the jobs container being replaced. Where
the monitoring lives and who receives it is in the house's private operator
inventory, not here. Being reported there is not the same as someone acting
on it.

Other signs: the resident's runs fail as unreachable or "container paused,
cause unconfirmed", and the host shows a paused container.

## Before unpausing

Run these on the host that runs the resident (see the private host
inventory).

1. **Exactly which resident and which container.**

   ```sh
   docker ps --filter status=paused --format '{{.Names}} {{.Status}}'
   echo "docker exit: $?"
   ```

   A non-zero exit means Docker didn't answer: stop. Match the name to one
   resident's `container_name`:

   ```ruby
   Agent.where(container_name: "<container>").pluck(:id, :name)
   ```

   Don't unpause a container you can't name. Other paused containers are
   triaged separately.

2. **Why it was paused.** Look for the backup that paused it: the "since"
   time in the StillPaused report, that resident's latest
   `Backup::AgentResticJob`, any running `FullBackupJob` or `Mnemodyne::FirstCheckpointJob`, and the
   last restart of the jobs container. If you can't find what paused it, you
   don't know why it is paused: escalate.

3. **Nothing can still reach it, and nothing new can start.** A full backup
   calls `Backup::AgentResticJob.perform_now` inside its loop over residents,
   (and `Mnemodyne::FirstCheckpointJob` calls it directly), so a `FullBackupJob` still in progress counts as active for this resident
   even if there is no separate job for her. Check, and treat a failed check
   as a stop, not as empty:

   ```sh
   out=$(docker ps --format '{{.Names}} {{.Image}}') || { echo "docker failed: stop"; exit 1; }
   printf '%s\n' "$out" | grep -E 'restic|busybox' || echo "no backup containers"
   ```

   ```ruby
   SolidQueue::Job.where(finished_at: nil).where("class_name LIKE '%Backup%'").pluck(:class_name, :arguments)
   Agent.where.not(backup_thinning_started_at: nil).pluck(:id)
   ```

   An empty snapshot doesn't stop new work starting. Agree a short window
   with an authorized operator in which no backup, thinning, restore, server
   move or deploy will start. If that window can't be established, escalate.

## Unpausing

Inside that window, check the same container is still paused, then unpause
it:

```sh
docker inspect --format '{{.State.Running}} {{.State.Paused}}' <container>   # expect: true true
docker unpause <container>
```

## Checking it worked

```sh
docker inspect --format '{{.State.Running}} {{.State.Paused}}' <container>   # want: true false
```

Then the resident's health goes green within a few minutes and a new run
succeeds. Record what you found and when you unpaused, where the problem was
raised.

## Escalating

If Docker doesn't answer, the container belongs to no resident you can
name, a backup or maintenance is still active, nothing explains the pause, or
no no-start window can be agreed: leave the container paused and tell the
house operator what you saw and which step stopped you.
