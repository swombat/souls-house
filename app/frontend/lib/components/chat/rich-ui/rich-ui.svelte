<script>
  import { Renderer, StateProvider, ActionProvider } from '@json-render/svelte';
  import { staticRichUi } from '$lib/rich-ui.js';
  import Stack from './stack.svelte';
  import Card from './card.svelte';
  import Text from './text.svelte';
  import Metric from './metric.svelte';
  import Table from './table.svelte';
  import Chart from './chart.svelte';

  let { value } = $props();
  let spec = $derived(staticRichUi(value));
  let json = $derived(spec ? JSON.stringify(spec, null, 2) : null);
  let downloadUrl = $state(null);
  // Components receive element.props, not arbitrary spread HTML props. None
  // consume emit, on, bindings, URLs, HTML, or application state.
  const registry = { Stack, Card, Text, Metric, Table, Chart };
  $effect(() => {
    if (!json || typeof URL.createObjectURL !== 'function') return;
    const url = URL.createObjectURL(new Blob([json], { type: 'application/json' }));
    downloadUrl = url;
    return () => {
      URL.revokeObjectURL(url);
      downloadUrl = null;
    };
  });
</script>

{#if value != null}
  <div class="my-4 min-w-0 space-y-3 text-foreground" data-testid="rich-ui">
    {#if spec}
      {#key spec}
        <svelte:boundary>
          <!-- Renderer requires both contexts, including for static specs.
               Empty handlers alone are NOT an action sandbox; validation is. -->
          <StateProvider initialState={{}}>
            <ActionProvider handlers={{}}>
              <Renderer {spec} {registry} />
            </ActionProvider>
          </StateProvider>
          {#snippet failed()}
            <p class="text-sm text-muted-foreground" role="status">
              This rich view could not be displayed. The message text is still available.
            </p>
          {/snippet}
        </svelte:boundary>
      {/key}
      <details>
        <summary class="cursor-pointer text-xs text-muted-foreground underline">View rich UI JSON</summary>
        <pre class="mt-2 max-h-80 overflow-auto rounded border border-border bg-muted p-3 text-xs">{json}</pre>
      </details>
      {#if downloadUrl}
        <a href={downloadUrl} download="rich-ui.json" class="text-xs text-muted-foreground underline">Download JSON</a>
      {/if}
    {:else}
      <p class="text-sm text-muted-foreground" role="status">
        This rich view is unsupported or invalid. The message text is still available.
      </p>
    {/if}
  </div>
{/if}
