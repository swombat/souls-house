<script>
  // A song's words in the Add/Edit dialog: the box (line breaks kept), the
  // Instrumental switch, and Find lyrics, which shows LRCLIB's candidates one
  // at a time with what they matched, to check before using. Typed words are
  // never replaced without asking; a failed or empty lookup leaves the box as
  // it was.
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Label } from '$lib/components/shadcn/label/index.js';
  import { formatSeconds, lyricsChoice, songLookup } from '$lib/field-songs';
  import { MagnifyingGlass } from 'phosphor-svelte';

  let {
    accountId,
    lyrics = $bindable(''),
    instrumental = $bindable(false),
    title = '',
    artist = '',
    durationMs = null,
    focus = false,
  } = $props();

  let candidates = $state(null);
  let index = $state(0);
  let looking = $state(false);
  let message = $state('');
  let box = $state(null);

  const candidate = $derived(candidates?.[index] || null);

  $effect(() => {
    if (focus && box) setTimeout(() => box?.focus(), 50);
  });

  async function findLyrics() {
    if (!title.trim()) {
      message = 'Give the title (and the artist, if you know it) to look for the lyrics.';
      return;
    }
    looking = true;
    message = '';
    candidates = null;
    index = 0;
    try {
      const params = { title: title.trim() };
      if (artist.trim()) params.artist = artist.trim();
      if (durationMs) params.duration_ms = durationMs;
      const data = await songLookup(accountId, params);
      candidates = data.candidates || [];
      if (!candidates.length) message = "LRCLIB doesn't know this one. You can paste the lyrics yourself.";
    } catch (e) {
      message = `${e.message}. You can paste the lyrics yourself.`;
    } finally {
      looking = false;
    }
  }

  function useCandidate() {
    if (!candidate) return;
    if (candidate.instrumental && !candidate.lyrics) {
      if (!lyrics.trim()) instrumental = true;
      candidates = null;
      return;
    }
    const choice = lyricsChoice(lyrics, candidate.lyrics);
    if (choice === 'confirm' && !confirm('Replace the lyrics already in the box with these?')) return;
    lyrics = candidate.lyrics;
    instrumental = false;
    candidates = null;
  }
</script>

<div class="space-y-1">
  <div class="flex flex-wrap items-end justify-between gap-2">
    <Label for="field-song-lyrics">Lyrics</Label>
    <Button
      type="button"
      variant="outline"
      size="sm"
      onclick={findLyrics}
      disabled={looking || instrumental}
      data-testid="field-song-find-lyrics">
      <MagnifyingGlass class="size-4" />
      {looking ? 'Looking…' : 'Find lyrics'}
    </Button>
  </div>
  {#if candidate}
    <div class="rounded-md border bg-muted/40 p-3 space-y-2 text-sm" data-testid="field-song-candidate">
      <p>
        <span class="font-medium">{candidate.title}</span>
        {#if candidate.artist}· {candidate.artist}{/if}
        {#if candidate.album}· {candidate.album}{/if}
        {#if candidate.duration_s}· {formatSeconds(candidate.duration_s)}{/if}
        <span class="text-muted-foreground">(match {index + 1} of {candidates.length}, from LRCLIB)</span>
      </p>
      {#if candidate.lyrics}
        <pre
          class="max-h-40 overflow-y-auto whitespace-pre-wrap font-sans text-xs text-muted-foreground">{candidate.lyrics}</pre>
      {:else if candidate.instrumental}
        <p class="text-muted-foreground">LRCLIB lists this one as instrumental.</p>
      {:else}
        <p class="text-muted-foreground">This match has no plain lyrics.</p>
      {/if}
      <p class="text-xs text-muted-foreground">Check it's the right song and version before using it.</p>
      <div class="flex flex-wrap gap-2">
        {#if candidate.lyrics || candidate.instrumental}
          <Button type="button" size="sm" onclick={useCandidate} data-testid="field-song-use-candidate">
            {candidate.lyrics ? (lyrics.trim() ? 'Replace with these' : 'Use these lyrics') : 'Mark as instrumental'}
          </Button>
        {/if}
        {#if index + 1 < candidates.length}
          <Button type="button" size="sm" variant="ghost" onclick={() => index++}>Next match</Button>
        {/if}
        <Button type="button" size="sm" variant="ghost" onclick={() => (candidates = null)}>Close</Button>
      </div>
    </div>
  {/if}
  {#if message}
    <p class="text-xs text-muted-foreground" role="status" data-testid="field-song-lyrics-message">{message}</p>
  {/if}
  <textarea
    id="field-song-lyrics"
    bind:this={box}
    bind:value={lyrics}
    disabled={instrumental}
    maxlength={20000}
    rows="8"
    class="w-full rounded-md border border-input bg-background px-3 py-2 text-sm disabled:opacity-50"
    placeholder={instrumental ? 'Instrumental: no words' : 'Paste the words. Line breaks are kept.'}
    data-testid="field-song-lyrics"></textarea>
  <label class="flex items-center gap-2 text-sm">
    <input
      type="checkbox"
      bind:checked={instrumental}
      disabled={!!lyrics.trim()}
      data-testid="field-song-instrumental" />
    Instrumental, no lyrics
  </label>
  {#if !lyrics.trim() && !instrumental}
    <p class="text-xs text-muted-foreground">
      You can share it now and add the lyrics later; until then it waits in Needs you.
    </p>
  {/if}
</div>
