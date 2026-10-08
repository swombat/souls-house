<script>
  import { DownloadSimple } from 'phosphor-svelte';

  let { feature } = $props();
  let Icon = $derived(feature.icon);
  // Respect reduced motion: show the poster frame and let the visitor start the clip themselves.
  const reduceMotion =
    typeof window !== 'undefined' && (window.matchMedia?.('(prefers-reduced-motion: reduce)').matches ?? false);
</script>

<article class="overflow-hidden rounded-2xl border bg-card" data-testid="feature-showcase">
  {#if feature.media?.kind === 'video'}
    <div class="group relative">
      <video
        class="aspect-video w-full border-b bg-muted object-cover"
        src={feature.media.src}
        poster={feature.media.poster}
        aria-label={feature.media.alt}
        autoplay={!reduceMotion}
        controls={reduceMotion}
        muted
        loop
        playsinline></video>
      <!-- An MP4 is what X, Bluesky and the rest take directly, so the share path is a download. -->
      <a
        href={feature.media.src}
        download={`souls-house-${feature.key}.mp4`}
        class="absolute right-3 top-3 inline-flex items-center gap-1.5 rounded-full bg-background/90 px-3 py-1.5 text-xs font-medium shadow-sm transition-opacity focus-visible:opacity-100 group-hover:opacity-100 [@media(hover:hover)]:opacity-0"
        data-testid="feature-clip-download">
        <DownloadSimple size={14} weight="bold" aria-hidden="true" />
        Download clip
      </a>
    </div>
  {:else if feature.media?.src}
    <img
      class="aspect-video w-full border-b bg-muted object-cover"
      src={feature.media.src}
      alt={feature.media.alt}
      loading="lazy" />
  {:else}
    <div class="flex aspect-video items-center justify-center border-b bg-muted/60" aria-hidden="true">
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
