<script>
  // One spinner for everyone working in a room or conversation: a ring per
  // resident, nested inside each other, each in that resident's colour. The
  // outermost is whoever started most recently; the tooltip names them all.
  // Past four rings it stops nesting (the tooltip still names everyone).
  const MAX_RINGS = 4;
  const STEP = 3; // px between nested rings
  const INNER = 12; // px, the innermost ring (and the whole spinner for one)

  let { agents = [] } = $props();

  const listFormat = new Intl.ListFormat('en', { type: 'conjunction' });

  function spinnerLabel(list) {
    if (!list.length) return '';
    const waking = list.filter((a) => a.phase === 'waking').map((a) => a.name);
    const working = list.filter((a) => a.phase !== 'waking').map((a) => a.name);
    if (!waking.length) return `${listFormat.format(working)} working`;
    if (!working.length) return `${listFormat.format(waking)} waking up`;
    const wakingPart = `${listFormat.format(waking)} waking up`;
    const workingPart = `${listFormat.format(working)} working`;
    return list[0].phase === 'waking' ? `${wakingPart}, ${workingPart}` : `${workingPart}, ${wakingPart}`;
  }

  const rings = $derived(agents.slice(0, MAX_RINGS));
  const size = $derived(INNER + 2 * STEP * Math.max(rings.length - 1, 0));
  const colour = $derived(agents[0]?.colour);
  const label = $derived(spinnerLabel(agents));

  function ringClass(agent) {
    return agent.colour ? `text-${agent.colour}-600 dark:text-${agent.colour}-300` : 'text-primary';
  }
</script>

{#if agents.length}
  <span
    data-testid="room-working"
    data-colour={colour || ''}
    role="img"
    aria-label={label}
    title={label}
    class="relative inline-block shrink-0"
    style="width: {size}px; height: {size}px">
    {#each rings as agent, i (agent.id ?? i)}
      <span
        data-testid="room-working-ring"
        data-colour={agent.colour || ''}
        aria-hidden="true"
        class="room-working-ring absolute rounded-full border-2 {ringClass(agent)}"
        class:reverse={i % 2 === 1}
        style="inset: {i * STEP}px; animation-duration: {1 + i * 0.35}s"></span>
    {/each}
  </span>
{/if}

<style>
  .room-working-ring {
    border-color: currentColor;
    border-right-color: transparent;
    border-bottom-color: transparent;
    animation: room-working-orbit 1s linear infinite;
  }

  .room-working-ring.reverse {
    animation-direction: reverse;
  }

  @keyframes room-working-orbit {
    to {
      transform: rotate(360deg);
    }
  }

  @media (prefers-reduced-motion: reduce) {
    .room-working-ring {
      animation: none;
      border-color: currentColor;
    }
  }
</style>
