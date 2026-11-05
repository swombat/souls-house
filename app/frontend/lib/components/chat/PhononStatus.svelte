<script>
  import { phononState } from '$lib/phonon-engine';

  // Phonon's state, said plainly where speech is asked for: the first-time
  // download (with how far it has got), the start-up on the graphics card, and
  // why it can't speak. Nothing once it is ready.
  let { testid = 'phonon-status' } = $props();

  const text = $derived(
    $phononState.status === 'downloading'
      ? `Downloading the voice engine (${$phononState.progress}% of about 52 MB, once; the browser keeps it)…`
      : $phononState.status === 'initialising'
        ? 'Starting the voice engine…'
        : $phononState.status === 'error'
          ? $phononState.error
          : ''
  );
</script>

{#if text}
  <p
    class="text-xs {$phononState.status === 'error' ? 'text-destructive' : 'text-muted-foreground'}"
    data-testid={testid}
    data-status={$phononState.status}>
    {text}
  </p>
{/if}
