<script>
  let { children } = $props();
</script>

<div class="flex min-w-0 flex-col gap-4">
  {@render children?.()}
</div>
