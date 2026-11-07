<script>
  let { element, children } = $props();
</script>

<section class="min-w-0 rounded-lg border border-border bg-card p-4 text-card-foreground">
  {#if element.props.title}
    <h3 class="mb-3 font-semibold">{element.props.title}</h3>
  {/if}
  <div class="flex flex-col gap-4">
    {@render children?.()}
  </div>
</section>
