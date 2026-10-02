<script>
  let { agents = [], overflow = 0, overflowCapped = false, active = false, stale = false, compact = false } = $props();

  // The server's run-local ordinal survives updates, gaps and reactivation.
  function colour(ordinal) {
    return `hsl(${Math.round(((ordinal - 1) * 137.508 + 220) % 360)} 65% 48%)`;
  }

  function working(agent) {
    return ['pending_init', 'running'].includes(agent.status);
  }

  function label(agent) {
    if (working(agent) && (!active || stale)) return 'Status unconfirmed';
    return (
      {
        pending_init: 'Starting',
        running: 'Working',
        completed: 'Completed',
        interrupted: 'Interrupted',
        errored: 'Failed',
        shutdown: 'Closed',
        not_found: 'Not found',
        unknown: 'Status unconfirmed',
      }[agent.status] || 'Status unconfirmed'
    );
  }

  function name(agent) {
    return agent.nickname || `Helper ${agent.ordinal}`;
  }
</script>

{#if agents.length || overflow > 0}
  {#if compact}
    <span class="ml-2 inline-flex flex-wrap items-center gap-1.5 align-middle" aria-label="Helpers started this turn">
      {#each agents as agent (agent.ordinal)}
        <span
          class="helper-dot"
          class:pulsing={active && !stale && working(agent)}
          style:background-color={colour(agent.ordinal)}
          role="img"
          aria-label={`${name(agent)} · ${label(agent)}`}
          title={`${name(agent)} · ${label(agent)}`}></span>
      {/each}
      {#if overflow > 0}
        <span class="text-xs text-muted-foreground">+{overflow} more{overflowCapped ? ' (at least)' : ''}</span>
      {/if}
    </span>
  {:else}
    <section aria-label="Helper details">
      <p class="mb-1 text-xs font-medium">Helpers started this turn</p>
      <ul class="space-y-1 text-xs">
        {#each agents as agent (agent.ordinal)}
          <li class="flex flex-wrap items-center gap-x-2 gap-y-1">
            <span class="helper-dot" style:background-color={colour(agent.ordinal)} aria-hidden="true"></span>
            <span class="font-medium">{name(agent)}</span>
            {#if agent.model}<span class="text-muted-foreground">{agent.model}</span>{/if}
            <span class="text-muted-foreground">{label(agent)}</span>
          </li>
        {/each}
      </ul>
      {#if overflow > 0}
        <p class="mt-1 text-xs text-muted-foreground">
          {overflowCapped ? 'At least ' : '+'}{overflow} more helpers; details omitted.
        </p>
      {/if}
    </section>
  {/if}
{/if}

<style>
  .helper-dot {
    display: inline-block;
    width: 0.5rem;
    height: 0.5rem;
    flex-shrink: 0;
    border-radius: 50%;
  }

  .pulsing {
    animation: helper-pulse 1.5s ease-in-out infinite;
  }

  @keyframes helper-pulse {
    50% {
      opacity: 0.35;
      transform: scale(0.8);
    }
  }

  @media (prefers-reduced-motion: reduce) {
    .pulsing {
      animation: none;
    }
  }
</style>
