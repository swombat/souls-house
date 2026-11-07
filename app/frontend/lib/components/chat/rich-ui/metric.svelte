<script>
  import { displayRichValue } from '$lib/rich-ui.js';
  let { element } = $props();
</script>

<dl class="min-w-0 [overflow-wrap:anywhere]">
  <dt class="text-sm text-muted-foreground">{element.props.label}</dt>
  <dd class="text-2xl font-semibold tabular-nums">{displayRichValue(element.props.value)}</dd>
  {#if element.props.detail}
    <dd class="mt-1 text-sm text-muted-foreground">{element.props.detail}</dd>
  {/if}
</dl>
