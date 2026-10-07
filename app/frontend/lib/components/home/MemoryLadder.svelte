<script>
  import { onMount } from 'svelte';

  // Days light up one by one, fold into weeks, the weeks fold into a month, and it begins again.
  let lit = $state(28);
  let phase = $state('month'); // 'days' | 'weeks' | 'month'

  onMount(() => {
    if (window.matchMedia?.('(prefers-reduced-motion: reduce)').matches) return;
    let t = 0;
    lit = 0;
    phase = 'days';
    const timer = setInterval(() => {
      t += 1;
      if (phase === 'days') {
        lit = Math.min(28, lit + 1);
        if (lit === 28) {
          phase = 'weeks';
          t = 0;
        }
      } else if (phase === 'weeks' && t > 12) {
        phase = 'month';
        t = 0;
      } else if (phase === 'month' && t > 18) {
        lit = 0;
        phase = 'days';
        t = 0;
      }
    }, 170);
    return () => clearInterval(timer);
  });

  const weeks = [0, 1, 2, 3];
</script>

<div class="rounded-3xl border bg-background p-6 shadow-sm" aria-hidden="true">
  <div class="grid grid-cols-4 gap-3">
    {#each weeks as w (w)}
      <div class="space-y-2">
        <div class="grid grid-cols-7 gap-1">
          {#each Array(7) as _, d (d)}
            {@const n = w * 7 + d}
            <span
              class="aspect-square rounded-[3px] transition-all duration-500 {n < lit
                ? 'bg-foreground/70'
                : 'bg-muted'} {phase !== 'days' ? 'scale-75 opacity-25' : ''}"></span>
          {/each}
        </div>
        <div
          class="h-6 rounded-md border text-center text-[11px] leading-6 text-muted-foreground transition-all duration-700 {phase !==
          'days'
            ? 'border-foreground/20 bg-muted opacity-100'
            : 'border-transparent opacity-0'}">
          week {w + 1}
        </div>
      </div>
    {/each}
  </div>
  <div
    class="mt-3 h-9 rounded-lg text-center text-xs font-medium leading-9 transition-all duration-700 {phase === 'month'
      ? 'bg-primary text-primary-foreground opacity-100'
      : 'opacity-0'}">
    the month, in their own words
  </div>
</div>
