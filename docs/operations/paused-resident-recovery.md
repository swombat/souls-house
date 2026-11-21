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

Once the cutover barrier (#1096) is live on the host, a routine Rails deploy
fences house backups out and defers rather than switch while any pause claim
is held; `docs/operations/github-deployments.md` has the detail. A stale claim
(`stale_pause_claims` in a deferred run; the probe's own key is `stale_claims`) means a resident is probably still
paused under a dead worker's claim: follow this runbook, and release the
claim only after the checks below; that is also what unblocks deploys. A
release from before the fence, a direct `kamal deploy`, or a jobs container
that dies for another reason (OOM, host reboot) can still leave a resident
paused.

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
   docker ps --no-trunc --filter status=paused --format '{{.ID}} {{.Names}} {{.Status}}'
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
   `Backup::AgentResticJob`, any running `FullBackupJob` or
   `Mnemodyne::FirstCheckpointJob`, and the last restart of the jobs container. If you can't find what paused it, you
   don't know why it is paused: escalate.

3. **Nothing can still reach it, and nothing new can start.** `FullBackupJob`
   calls `Backup::AgentResticJob.perform_now` inside its loop over residents,
   and `Mnemodyne::FirstCheckpointJob` calls it directly, so either one still
   in progress counts as active for this resident even without a separate
   job for her. Check, and treat a failed check
   as a stop, not as empty:

   ```sh
   docker ps --no-trunc --format '{{.ID}} {{.Names}} {{.Image}}'
   echo "docker exit: $?"
   ```

   A non-zero exit means stop. Otherwise read the whole listing for restic,
   busybox or any other backup container that could touch this resident.

   ```ruby
   SolidQueue::Job.where(finished_at: nil)
     .where("class_name LIKE '%Backup%' OR class_name IN (?)", %w[FullBackupJob Mnemodyne::FirstCheckpointJob])
     .pluck(:class_name, :arguments)
   Agent.where.not(backup_thinning_started_at: nil).pluck(:id)
   ```

   An empty snapshot doesn't stop new work starting. Agree a short window
   with an authorized operator in which no backup, thinning, restore, server
   move or deploy will start. If that window can't be established, escalate.

## Unpausing

Inside that window, take the container ID from step 1 and unpause only if
Docker confirms, for that same ID, that it is running and paused:

```sh
id=<container-id>
if state=$(docker inspect --format '{{.State.Running}} {{.State.Paused}}' "$id") \
   && [ "$state" = "true true" ]; then
  docker unpause "$id"
else
  echo "not unpausing: inspect failed or state was '$state'"
fi
```

## Checking it worked

```sh
docker inspect --format '{{.State.Running}} {{.State.Paused}}' "$id"   # want: true false
```

Then the resident's health goes green within a few minutes and a new run
succeeds. Record what you found and when you unpaused, where the problem was
raised.

## Releasing a stale pause claim

A routine deploy defers while any `Backup::PauseClaim` exists (#1096). A claim
listed in `stale_pause_claims` has stopped beating. Its backup is most likely
dead. Release it only with evidence for that exact claim, never because the
heartbeat has gone quiet:

1. **Read the claim.**

   ```ruby
   c = Backup::PauseClaim.find_by!(agent_id: <id>)
   [c.container_id, c.token, c.created_at, c.touched_at]
   ```

2. **Establish that its backup is gone.** Do checks 2 and 3 above for this
   resident: no backup job in progress that could still reach them, no backup
   container for them in the full `docker ps` listing, and an agreed no-start
   window. If any check fails, leave the claim and escalate.

3. **Look at the container the claim names**, by the claim's own id, not by
   name:

   ```sh
   docker inspect --format '{{.Id}} {{.State.Running}} {{.State.Paused}}' "<container_id>"
   echo "docker exit: $?"
   ```

   - `true true`: that container is paused. The claim naming it doesn't prove
     its backup took this pause. Treat it as any paused resident: every check
     in "Before unpausing", then "Unpausing" and "Checking it worked", and only
     then release.
   - `true false`: running now. Release.
   - No such container (exit non-zero with "No such object"; the resident was
     rebuilt): look up the resident's current container and inspect it the
     same way. Release only on `true false` and a green health check for the
     resident. Not appearing in a paused-only listing isn't enough.
   - Any other failure or output: Docker didn't answer clearly. Stop.

4. **Release exactly that claim**, by its token, so a newer claim made in the
   meantime survives:

   ```ruby
   Backup::PauseClaim.where(agent_id: <id>, token: "<token>").delete_all   # want: 1
   Backup::PauseClaim.where(agent_id: <id>).pluck(:token)                 # want: []
   ```

   `0` means the claim had already gone or been replaced: stop and read the
   claims again. Anything other than `[]` afterwards is a newer claim, made by
   a backup that is running now. Leave it.

5. **Check the deploy probe agrees.** Run the installed probe in the live web
   container:

   ```sh
   c=$(docker ps --format '{{.Names}}' | grep '^souls-house-web-')
   docker exec -i "$c" bin/rails runner - < /opt/house-deploy/backup-in-flight.rb
   echo "probe exit: $?"
   ```

   It must exit 0 and print one JSON line with `thinning`, `backing_up` and
   `stale_claims`, and the resident must be in neither `backing_up` nor
   `stale_claims`. A non-zero exit or no JSON is no answer: stop. If the
   resident is still listed, a new claim has been made or the release didn't
   commit. Stop and look again.

   Then rerun the deferred deploy (or let the next merge deploy). Record what
   you found, where the problem was raised.

## A deploy that reports a held fence

`backup_fence: held` means a release switch failed and its Kamal tools
container (`house-deploy-kamal-<run id>`) couldn't be removed, so the switch
may still be running. The fence is left up on purpose and expires by itself
(the wait limit plus Kamal's two-hour timeout and margins). House backups are
busy-retried until then. The run itself ended failed, so the gate wants the
usual acknowledgement before the next deploy.

1. Check the tools container: `docker ps -a --filter name=house-deploy-kamal-<run id>`.
   While it's running, leave everything alone. If it's still running two
   hours after the run started (Kamal's own timeout), or Docker doesn't
   answer: escalate.
2. Once it has exited (or is gone), check what's live: exactly one
   `souls-house-web-*` and one `souls-house-jobs-*`, both of the same
   revision, and the health URL answering. If not, that's a failed deploy:
   escalate, and leave the fence up.
3. Then lower the fence early if backups need to run before it expires:

   ```ruby
   Backup::DeployFence.lower!("<run id>")
   Backup::DeployFence.up?   # want: false
   ```

   Remove the exited tools container with `docker rm house-deploy-kamal-<run id>`.

## Escalating

If Docker doesn't answer, the container belongs to no resident you can
name, a backup or maintenance is still active, nothing explains the pause, or
no no-start window can be agreed: leave the container paused and tell the
house operator what you saw and which step stopped you.
