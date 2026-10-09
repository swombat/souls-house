<script>
  import { DownloadSimple } from 'phosphor-svelte';

  let { entries } = $props();
  // Same rule as the feature clips: with reduced motion, show the poster and let the visitor press play.
  const reduceMotion =
    typeof window !== 'undefined' && (window.matchMedia?.('(prefers-reduced-motion: reduce)').matches ?? false);

  const groups = $derived.by(() => {
    const byDate = [];
    for (const entry of entries) {
      const last = byDate.at(-1);
      if (last?.date === entry.date) last.entries.push(entry);
      else byDate.push({ date: entry.date, entries: [entry] });
    }
    return byDate;
  });

  function formatDate(iso) {
    return new Date(`${iso}T12:00:00Z`).toLocaleDateString('en-GB', {
      day: 'numeric',
      month: 'long',
      year: 'numeric',
      timeZone: 'UTC',
    });
  }
</script>

<ol class="space-y-8" data-testid="changelog">
  {#each groups as group (group.date)}
    <li class="grid gap-3 sm:grid-cols-[10rem_1fr] sm:gap-6">
      <time datetime={group.date} class="text-sm font-medium text-muted-foreground sm:pt-0.5">
        {formatDate(group.date)}
      </time>
      <ul class="space-y-4">
        {#each group.entries as entry (entry.title)}
          <li data-testid="changelog-entry">
            <p class="font-medium">{entry.title}</p>
            <p class="mt-1 text-sm leading-relaxed text-muted-foreground">{entry.body}</p>
            {#if entry.clip}
              <div class="group relative mt-3 max-w-xl overflow-hidden rounded-xl border bg-muted">
                <video
                  class="aspect-video w-full object-cover"
                  src={entry.clip.src}
                  poster={entry.clip.poster}
                  aria-label={`Clip: ${entry.title}`}
                  autoplay={!reduceMotion}
                  controls={reduceMotion}
                  preload="metadata"
                  muted
                  loop
                  playsinline
                  data-testid="changelog-clip"></video>
                <a
                  href={entry.clip.src}
                  download={`souls-house-${entry.clip.name}.mp4`}
                  class="absolute right-3 top-3 inline-flex items-center gap-1.5 rounded-full bg-background/90 px-3 py-1.5 text-xs font-medium shadow-sm transition-opacity focus-visible:opacity-100 group-hover:opacity-100 [@media(hover:hover)]:opacity-0">
                  <DownloadSimple size={14} weight="bold" aria-hidden="true" />
                  Download clip
                </a>
              </div>
            {/if}
          </li>
        {/each}
      </ul>
    </li>
  {/each}
</ol>
