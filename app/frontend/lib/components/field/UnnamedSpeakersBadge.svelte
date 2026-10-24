<script>
  // A small amber mark on a recording whose speakers aren't all named yet:
  // a dashed figure (someone not yet known) and how many are waiting.
  import { UserCircleDashed } from 'phosphor-svelte';

  let { count = 0, size = 'sm' } = $props();

  const label = $derived(count === 1 ? '1 speaker to name' : `${count} speakers to name`);
</script>

{#if count > 0}
  <span
    class="inline-flex shrink-0 items-center gap-0.5 rounded-full bg-amber-100 px-1.5 py-0.5 font-medium tabular-nums text-amber-800 dark:bg-amber-950 dark:text-amber-300 {size ===
    'sm'
      ? 'text-[11px] leading-none'
      : 'text-xs'}"
    title={label}
    aria-label={label}
    data-testid="field-unnamed-speakers">
    <UserCircleDashed class={size === 'sm' ? 'size-3.5' : 'size-4'} weight="bold" aria-hidden="true" />
    {#if size !== 'sm'}{label}{:else}{count}{/if}
  </span>
{/if}
