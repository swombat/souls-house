<script>
  import { siteName } from '$lib/branding';
  import { ArrowLeft, ArrowRight, ClockCounterClockwise, DownloadSimple } from 'phosphor-svelte';

  // One changelog entry on its own page, so a post about one change can link to it.
  // The description is the server's, the same words its link preview gives crawlers.
  let { entry, description } = $props();

  const reduceMotion =
    typeof window !== 'undefined' && (window.matchMedia?.('(prefers-reduced-motion: reduce)').matches ?? false);

  function formatDate(iso) {
    return new Date(`${iso}T12:00:00Z`).toLocaleDateString('en-GB', {
      day: 'numeric',
      month: 'long',
      year: 'numeric',
      timeZone: 'UTC',
    });
  }
</script>

<svelte:head>
  <title>{entry.title} — {$siteName}</title>
  <meta name="description" content={description} />
</svelte:head>

<div class="mx-auto max-w-3xl px-6 py-12 sm:py-20">
  <p class="mb-5 text-sm font-medium text-muted-foreground">
    <a href="/changelog" class="inline-flex items-center gap-2 hover:text-foreground" data-testid="changelog-entry-back">
      <ClockCounterClockwise size={18} /> Changelog
    </a>
  </p>

  <article data-testid="changelog-entry-page">
    <time datetime={entry.date} class="text-sm font-medium text-muted-foreground">{formatDate(entry.date)}</time>
    <h1 class="mt-2 text-3xl font-semibold tracking-tight sm:text-4xl">{entry.title}</h1>
    <p class="mt-5 text-lg leading-relaxed text-muted-foreground">{entry.body}</p>

    {#if entry.clip}
      <div class="group relative mt-8 overflow-hidden rounded-xl border bg-muted">
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
  </article>

  <nav class="mt-12 grid gap-4 border-t pt-6 text-sm sm:grid-cols-2" aria-label="Other changes">
    {#if entry.older}
      <a href={`/changelog/${entry.older.slug}`} class="group block" data-testid="changelog-entry-older">
        <span class="inline-flex items-center gap-1.5 text-muted-foreground"><ArrowLeft size={14} /> Before this</span>
        <span class="mt-1 block font-medium group-hover:underline">{entry.older.title}</span>
      </a>
    {:else}
      <span></span>
    {/if}
    {#if entry.newer}
      <a href={`/changelog/${entry.newer.slug}`} class="group block sm:text-right" data-testid="changelog-entry-newer">
        <span class="inline-flex items-center gap-1.5 text-muted-foreground">After this <ArrowRight size={14} /></span>
        <span class="mt-1 block font-medium group-hover:underline">{entry.newer.title}</span>
      </a>
    {/if}
  </nav>

  <p class="mt-10 text-sm"><a href="/changelog" class="underline underline-offset-4">The whole changelog</a></p>
</div>
