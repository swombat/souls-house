<script>
  import Sparkline from './Sparkline.svelte';

  let { label, value, detail = null, tone = 'neutral', spark = null, sparkColor = '#14b8a6', hint = '' } = $props();

  const toneClass = $derived(
    {
      neutral: 'text-muted-foreground',
      up: 'text-teal-600 dark:text-teal-400',
      down: 'text-rose-500',
      alert: 'text-rose-600 dark:text-rose-400 font-medium',
    }[tone] || 'text-muted-foreground'
  );
</script>

<div class="rounded-xl border bg-card p-4 flex flex-col gap-2 min-w-0" title={hint}>
  <div class="text-xs uppercase tracking-wide text-muted-foreground">{label}</div>
  <div class="flex items-end justify-between gap-3">
    <div class="text-3xl font-semibold tabular-nums leading-none" class:text-rose-600={tone === 'alert'}>{value}</div>
    {#if spark}
      <div class="shrink-0" style:color={sparkColor}>
        <Sparkline values={spark} width={84} height={28} color={sparkColor} label={`${label} trend`} />
      </div>
    {/if}
  </div>
  <div class={`text-xs ${toneClass} min-h-4`}>{detail ?? ''}</div>
</div>
