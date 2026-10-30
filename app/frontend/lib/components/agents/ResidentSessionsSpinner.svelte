<script>
  // A resident's runs going right now, for the card header: the total, and a
  // spinner with one ring per kind that has a run, nested: chat outermost,
  // Telegram, then everything else (heartbeats, memory formation…). Chat and
  // Telegram take the Messages chart's colours. Nothing at zero.
  const STEP = 3; // px between nested rings
  const INNER = 12; // px, the innermost ring

  let { sessions = null } = $props();

  const KINDS = [
    { key: 'chat', label: 'chat', ring: 'text-emerald-500 dark:text-emerald-400' },
    { key: 'telegram', label: 'Telegram', ring: 'text-sky-500 dark:text-sky-400' },
    { key: 'other', label: 'other', ring: 'text-indigo-500 dark:text-indigo-400' },
  ];

  const present = $derived(KINDS.filter((kind) => (sessions?.[kind.key] || 0) > 0));
  const total = $derived(present.reduce((sum, kind) => sum + sessions[kind.key], 0));
  const size = $derived(INNER + 2 * STEP * Math.max(present.length - 1, 0));
  const label = $derived(
    `${total} active ${total === 1 ? 'session' : 'sessions'}: ${present
      .map((kind) => `${sessions[kind.key]} ${kind.label}`)
      .join(' · ')}`
  );
</script>

{#if total > 0}
  <span
    data-testid="resident-sessions"
    data-total={total}
    class="inline-flex shrink-0 items-center gap-1.5 text-xs font-medium tabular-nums text-muted-foreground"
    title={label}>
    <span aria-hidden="true">{total}</span>
    <span role="img" aria-label={label} class="relative inline-block" style="width: {size}px; height: {size}px">
      {#each present as kind, i (kind.key)}
        <span
          data-testid="resident-sessions-ring"
          data-kind={kind.key}
          aria-hidden="true"
          class="resident-sessions-ring absolute rounded-full border-2 {kind.ring}"
          class:reverse={i % 2 === 1}
          style="inset: {i * STEP}px; animation-duration: {1 + i * 0.35}s"></span>
      {/each}
    </span>
  </span>
{/if}

<style>
  .resident-sessions-ring {
    border-color: currentColor;
    border-right-color: transparent;
    border-bottom-color: transparent;
    animation: resident-sessions-orbit 1s linear infinite;
  }

  .resident-sessions-ring.reverse {
    animation-direction: reverse;
  }

  @keyframes resident-sessions-orbit {
    to {
      transform: rotate(360deg);
    }
  }

  @media (prefers-reduced-motion: reduce) {
    .resident-sessions-ring {
      animation: none;
      border-color: currentColor;
    }
  }
</style>
