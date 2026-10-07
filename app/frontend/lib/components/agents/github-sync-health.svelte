<script>
  let { health = null } = $props();
  const states = {
    unknown: 'Sync not confirmed',
    ok: 'Last sync check succeeded',
    busy: 'Sync runner busy',
    blocked: 'Sync blocked',
    needs_attention: 'Sync needs attention',
    failed: 'Sync failed',
    stale: 'Sync report is stale',
  };
  const reasons = {
    not_recorded: 'No sync report has been recorded.',
    runtime_unavailable: 'The runtime health check is unavailable.',
    synced: 'The selected branch was synchronized at the reported check.',
    lock_busy: 'Another sync cycle holds the local lock. This cycle did not confirm sync.',
    staged_changes: 'Existing staged changes need review before another cycle.',
    dirty_worktree: 'Uncommitted edits outside the eligible policy need manual review.',
    operation_in_progress: 'Finish or deliberately abort the existing Git operation before retrying.',
    wrong_branch: 'Check the selected branch in the working copy before retrying.',
    invalid_configuration: 'Review the root, branch and manifest policy before retrying.',
    commit_failed: 'The eligible changes could not be committed. Review the local repository.',
    fetch_failed: 'Fetching origin failed. Check connectivity and repository access.',
    merge_conflict: 'Integration stopped on a conflict. Preserve both sides and reconcile deliberately.',
    integration_failed: 'Integration did not complete. Review the preserved local commits before retrying.',
    push_failed: 'Pushing the selected branch failed. Check origin access and retry after review.',
    timed_out: 'The sync attempt timed out without confirming synchronization.',
    runner_failed: 'The runner did not complete. The resident can inspect its own checkout.',
    stale: 'The cached report is too old to confirm current sync.',
    protected_deletion: 'Deletion of a protected path was refused. Review the intended change manually.',
    protected_shrink: 'A protected path shrank below its reviewed threshold. Review the change manually.',
    append_only_violation: 'Rewriting or truncating an append-only path was refused. Preserve and review both sides.',
  };
  let rescueAttempted = $derived(['pushed', 'failed'].includes(health?.rescue_status));
  let state = $derived(
    rescueAttempted && health?.state === 'ok' ? 'needs_attention' : states[health?.state] ? health.state : 'unknown'
  );
  let reason = $derived(
    rescueAttempted && health?.reason_code === 'synced'
      ? reasons.integration_failed
      : reasons[health?.reason_code] || reasons.not_recorded
  );
  function age(seconds) {
    if (!Number.isFinite(seconds) || seconds < 0) return 'Age unavailable';
    if (seconds < 60) return 'Less than a minute ago';
    const [count, unit] =
      seconds < 3600
        ? [Math.floor(seconds / 60), 'minute']
        : seconds < 86400
          ? [Math.floor(seconds / 3600), 'hour']
          : [Math.floor(seconds / 86400), 'day'];
    return `${count} ${unit}${count === 1 ? '' : 's'} ago`;
  }
</script>

<section class="space-y-3 rounded-lg border p-5" aria-label="Home sync health">
  <h2 class="text-lg font-semibold">{states[state]}</h2>
  <p class="text-sm">{reason}</p>
  <dl class="grid gap-2 text-sm sm:grid-cols-[auto_1fr]">
    <dt class="text-muted-foreground">Last confirmed sync</dt>
    <dd>
      {#if health?.last_success_at}
        <time datetime={health.last_success_at}>{health.last_success_at}</time>
        <span class="block text-muted-foreground">{age(health.last_success_age_seconds)} (reported age)</span>
      {:else}
        Not yet confirmed
      {/if}
    </dd>
    <dt class="text-muted-foreground">Report checked</dt>
    <dd>{health?.checked_at || 'Not recorded'}</dd>
  </dl>
  {#if health?.rescue_status === 'pushed' || health?.rescue_status === 'failed'}
    <div class="space-y-2 rounded-md border p-3 text-sm">
      <p class="font-medium">
        {health.rescue_status === 'pushed'
          ? 'Local commits pushed to a separate rescue ref'
          : 'Rescue push failed — keep the local working copy'}
      </p>
      {#if health.rescue_ref}
        <p class="break-all"><code>{health.rescue_ref}</code></p>
      {/if}
      <p>
        Rescue is not a successful sync of the selected branch. Local commits are preserved; reconcile both sides from
        the resident's own checkout before retrying. No site-admin approval is required. Do not discard the working copy
        or force-push over the other host.
      </p>
    </div>
  {/if}
  <p class="text-sm text-muted-foreground">
    This is a cached check, not live proof that every host is up to date. Unknown, stale or partial rescue outcomes
    never confirm synchronization. Import readiness, sync and external-memory access are separate checks.
  </p>
</section>
