<script>
  import Carousel from '$lib/components/home/Carousel.svelte';
  import ClipVideo from '$lib/components/home/ClipVideo.svelte';

  // The latest changelog entries; pressing next on the last one opens the full changelog.
  let { entries = [] } = $props();
  const items = $derived(entries.map((entry, i) => ({ ...entry, key: `${entry.date}-${i}` })));

  function formatDate(iso) {
    return new Date(`${iso}T12:00:00Z`).toLocaleDateString('en-GB', {
      day: 'numeric',
      month: 'long',
      timeZone: 'UTC',
    });
  }
</script>

<Carousel
  {items}
  label="Latest changes"
  endHref="/changelog"
  endLabel="Full changelog"
  slideClass="w-[85%] sm:w-[45%] lg:w-[31%]"
  testid="changelog-carousel">
  {#snippet slide(entry)}
    <article class="flex h-full flex-col overflow-hidden rounded-2xl border bg-card">
      {#if entry.clip}
        <div class="border-b">
          <ClipVideo src={entry.clip.src} poster={entry.clip.poster} alt={`Clip: ${entry.title}`} />
        </div>
      {/if}
      <div class="flex-1 p-5">
        <time datetime={entry.date} class="text-xs font-medium tracking-wide text-muted-foreground uppercase">
          {formatDate(entry.date)}
        </time>
        <h3 class="mt-2 font-semibold tracking-tight">{entry.title}</h3>
        <p class="mt-2 line-clamp-5 text-sm leading-relaxed text-muted-foreground">{entry.body}</p>
      </div>
    </article>
  {/snippet}
</Carousel>
