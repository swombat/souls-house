<script>
  import { CaretDown } from 'phosphor-svelte';

  let { features } = $props();
</script>

<ul class="grid items-start gap-2 sm:grid-cols-2 lg:grid-cols-3" data-testid="feature-index">
  {#each features as feature (feature.key)}
    {@const Icon = feature.icon}
    <li>
      <details class="group rounded-xl border bg-card">
        <summary class="flex cursor-pointer list-none items-center gap-3 px-4 py-3 [&::-webkit-details-marker]:hidden">
          <Icon size={22} weight="duotone" class="shrink-0 text-primary" />
          <span class="flex-1 text-sm font-medium">{feature.title}</span>
          <CaretDown size={16} class="shrink-0 text-muted-foreground transition-transform group-open:rotate-180" />
        </summary>
        <p class="px-4 pb-4 pl-[3.25rem] text-sm leading-relaxed text-muted-foreground">{feature.description}</p>
      </details>
    </li>
  {/each}
</ul>
