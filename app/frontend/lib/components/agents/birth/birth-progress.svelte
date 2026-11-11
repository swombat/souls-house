<script>
  // The creation wizard's steps as numbered dots. A step already passed can be
  // gone back to; the ones ahead are reached with Continue.
  import { Check } from 'phosphor-svelte';

  let { steps = [], step = $bindable(0) } = $props();
</script>

<nav class="mb-10" aria-label="Creation progress">
  <ol class="flex items-start">
    {#each steps as label, index}
      {#if index > 0}
        <div
          class="mt-4 h-0.5 min-w-4 flex-1 rounded-full transition-colors {index <= step ? 'bg-primary' : 'bg-border'}">
        </div>
      {/if}
      <li class="flex flex-col items-center gap-1.5">
        <button
          type="button"
          class="flex size-8 items-center justify-center rounded-full border-2 text-xs font-semibold transition-colors
            {index < step
            ? 'border-primary bg-primary text-primary-foreground hover:bg-primary/90'
            : index === step
              ? 'border-primary bg-background text-primary'
              : 'border-border bg-background text-muted-foreground/60'}"
          onclick={() => {
            if (index < step) step = index;
          }}
          disabled={index >= step}
          aria-label="Go to step {index + 1}: {label}"
          aria-current={index === step ? 'step' : undefined}>
          {#if index < step}
            <Check class="size-4" weight="bold" />
          {:else}
            {index + 1}
          {/if}
        </button>
        <span
          class="max-w-20 truncate px-1 text-xs {index === step
            ? 'font-semibold text-foreground'
            : 'text-muted-foreground'}">
          {label}
        </span>
      </li>
    {/each}
  </ol>
</nav>
