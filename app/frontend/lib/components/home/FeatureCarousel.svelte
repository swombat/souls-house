<script>
  import Carousel from '$lib/components/home/Carousel.svelte';
  import ClipVideo from '$lib/components/home/ClipVideo.svelte';
  import { alternatingClipFeatures } from '$lib/components/home/feature-carousel.js';

  const features = alternatingClipFeatures();
</script>

<Carousel items={features} label="Features" autoplayMs={6000} testid="feature-carousel">
  {#snippet slide(feature)}
    <article class="flex h-full flex-col overflow-hidden rounded-2xl border bg-card">
      <div class="border-b">
        <ClipVideo src={feature.media.src} poster={feature.media.poster} alt={feature.media.alt} />
      </div>
      <div class="flex-1 p-5 sm:p-6">
        <p class="text-xs font-medium tracking-wide text-muted-foreground uppercase">{feature.side}</p>
        <h3 class="mt-2 text-lg font-semibold tracking-tight">{feature.title}</h3>
        <p class="mt-2 text-sm leading-relaxed text-muted-foreground">{feature.description}</p>
      </div>
    </article>
  {/snippet}
</Carousel>
