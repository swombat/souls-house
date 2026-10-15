<script>
  // A spinner beside a room's name while residents are working there, in the
  // colour of the one who started most recently; the tooltip names them all.
  let { agents = [] } = $props();

  const colour = $derived(agents[0]?.colour);
  const label = $derived(
    agents.length ? `${new Intl.ListFormat('en', { type: 'conjunction' }).format(agents.map((a) => a.name))} working` : ''
  );
</script>

{#if agents.length}
  <span
    data-testid="room-working"
    data-colour={colour || ''}
    role="img"
    aria-label={label}
    title={label}
    class="room-working inline-block size-3 shrink-0 rounded-full border-2 {colour
      ? `text-${colour}-600 dark:text-${colour}-300`
      : 'text-primary'}"></span>
{/if}

<style>
  .room-working {
    border-color: currentColor;
    border-right-color: transparent;
    border-bottom-color: transparent;
    animation: room-working-orbit 1s linear infinite;
  }

  @keyframes room-working-orbit {
    to {
      transform: rotate(360deg);
    }
  }

  @media (prefers-reduced-motion: reduce) {
    .room-working {
      animation: none;
      border-color: currentColor;
    }
  }
</style>
