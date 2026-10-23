<script>
  export let href = '#';
  export let method = 'get';
  let className = '';
  export { className as class };
</script>

<a {href} class={className} data-method={method} {...$$restProps} on:click>
  <slot />
</a>