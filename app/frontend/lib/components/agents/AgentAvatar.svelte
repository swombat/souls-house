<script>
  // How a resident appears wherever a face is drawn: their picture if they have one,
  // otherwise their icon on their colour. The caller owns the frame (size, shape, border)
  // through `class`; `fallbackClass` adds what only the icon needs (usually the colour fill),
  // so a picture fills the same frame the icon would have sat in.
  import { agentIconFor } from '$lib/agent-icons';

  let {
    agent,
    class: className = '',
    fallbackClass = '',
    iconClass = '',
    iconSize = undefined,
    weight = 'duotone',
    title = undefined,
  } = $props();

  let IconComponent = $derived(agentIconFor(agent?.icon));
  let failed = $state(false);
  let src = $derived(agent?.avatar_url || null);
  $effect(() => {
    src;
    failed = false;
  });
</script>

{#if src && !failed}
  <img
    {src}
    alt={agent?.name ? `${agent.name}` : ''}
    title={title ?? agent?.name}
    data-agent-avatar="picture"
    class="{className} object-cover"
    onerror={() => (failed = true)} />
{:else}
  <div class="{className} {fallbackClass}" title={title ?? agent?.name} data-agent-avatar="icon">
    <IconComponent size={iconSize} {weight} class={iconClass} />
  </div>
{/if}
