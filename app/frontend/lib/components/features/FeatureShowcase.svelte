<script>
  let { feature } = $props();
  let Icon = $derived(feature.icon);
</script>

<article class="overflow-hidden rounded-2xl border bg-card" data-testid="feature-showcase">
  {#if feature.media?.kind === 'video'}
    <video
      class="aspect-video w-full border-b bg-muted object-cover"
      src={feature.media.src}
      aria-label={feature.media.alt}
      autoplay
      muted
      loop
      playsinline></video>
  {:else if feature.media?.src}
    <img
      class="aspect-video w-full border-b bg-muted object-cover"
      src={feature.media.src}
      alt={feature.media.alt}
      loading="lazy" />
  {:else}
    <div class="flex h-24 items-center justify-center border-b bg-muted/60 sm:h-28" aria-hidden="true">
      <Icon size={52} weight="duotone" class="text-primary" />
    </div>
  {/if}
  <div class="p-5 sm:p-6">
    <h3 class="text-lg font-semibold tracking-tight">{feature.title}</h3>
    <p class="mt-2 text-sm leading-relaxed text-muted-foreground">{feature.description}</p>
    {#if feature.link}
      <a href={feature.link} class="mt-3 inline-block text-sm font-medium underline underline-offset-4">Read more</a>
    {/if}
  </div>
</article>
