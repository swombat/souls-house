<script>
  import { Link } from '@inertiajs/svelte';
  import { Waves } from 'phosphor-svelte';
  import { formatWhen } from '$lib/rhythms';

  let { provenance } = $props();

  const when = $derived(formatWhen(provenance?.scheduled_for, undefined, { withYear: false }));
</script>

{#if provenance}
  <div class="mb-1 flex justify-end">
    <span
      class="inline-flex items-center gap-1.5 rounded-full border border-border bg-muted/40 px-2.5 py-0.5 text-xs text-muted-foreground"
      title={when ? `Scheduled for ${when}` : undefined}>
      <Waves size={12} weight="duotone" />
      <span>{provenance.manual ? 'Started now by' : 'Scheduled by'} {provenance.creator_name}</span>
      <span aria-hidden="true">·</span>
      {#if provenance.rhythm_url}
        <Link href={provenance.rhythm_url} class="underline-offset-2 hover:underline">Rhythm: {provenance.title}</Link>
      {:else}
        <span>Rhythm: {provenance.title}</span>
      {/if}
    </span>
  </div>
{/if}
