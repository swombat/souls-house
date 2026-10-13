<script>
  // Share a song in the Field, or edit one: a way to hear it (a link, an
  // audio file, or both), its name, its words, why, and for whom. A link
  // fills in the title and artist where the provider says them; Find lyrics
  // offers LRCLIB's candidates to check, and never replaces typed words
  // without asking.
  import { router } from '@inertiajs/svelte';
  import * as Dialog from '$lib/components/shadcn/dialog/index.js';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Input } from '$lib/components/shadcn/input/index.js';
  import { Label } from '$lib/components/shadcn/label/index.js';
  import { formatBytes } from '$lib/field';
  import { guessFromFilename, songLookup } from '$lib/field-songs';
  import FieldSongLyricsInput from './FieldSongLyricsInput.svelte';
  import { Plus } from 'phosphor-svelte';

  let {
    open = $bindable(false),
    accountId,
    song = null,
    focusLyrics = false,
    recipients = [],
    maxBytes,
    maxLabel,
    sharedLine = '',
  } = $props();

  const MAX_LINKS = 4;

  let links = $state(['']);
  let audioFile = $state(null);
  let title = $state('');
  let artist = $state('');
  let album = $state('');
  let year = $state('');
  let lyrics = $state('');
  let instrumental = $state(false);
  let note = $state('');
  let sharedFor = $state('');
  let date = $state('');
  let error = $state('');
  let saving = $state(false);

  let linkMessage = $state('');
  let linkLooking = $state(false);
  let lastLookedUp = '';
  // Bumped on every reset and every new link lookup: an answer that comes
  // back for an older link, or an earlier opening of the dialog, is dropped.
  let lookupGeneration = 0;
  // What the file's name suggests. Shown greyed in the empty boxes and never
  // sent: left blank, the server reads the file's own tags first and falls
  // back to its name only when they say nothing.
  let guess = $state({ title: '', artist: '' });

  const editing = $derived(!!song);
  const hasAudio = $derived(!!audioFile || !!song?.audio);
  const hearable = $derived(hasAudio || links.some((l) => l.trim()));
  const tooLarge = $derived(!!audioFile && audioFile.size > maxBytes);

  // Each time the dialog opens it starts from the song (or empty).
  let wasOpen = false;
  $effect(() => {
    if (open && !wasOpen) reset();
    wasOpen = open;
  });

  function reset() {
    links = song?.links?.length ? song.links.map((l) => l.url) : [''];
    audioFile = null;
    title = song?.title || '';
    artist = song?.artist || '';
    album = song?.album || '';
    year = song?.year ? String(song.year) : '';
    lyrics = song?.lyrics || '';
    instrumental = !!song?.instrumental;
    note = song?.note || '';
    sharedFor = song?.shared_for_key || '';
    date = song?.dated_at ? song.dated_at.slice(0, 10) : '';
    error = '';
    linkMessage = '';
    linkLooking = false;
    lookupGeneration += 1;
    guess = { title: '', artist: '' };
    lastLookedUp = links[0] || '';
  }

  // The first link pasted: ask its provider for the title and artist, and
  // fill only what is still empty.
  async function lookUpLink() {
    const url = (links[0] || '').trim();
    if (!url || url === lastLookedUp) return;
    lastLookedUp = url;
    const generation = ++lookupGeneration;
    const current = () => generation === lookupGeneration && open && (links[0] || '').trim() === url;
    linkLooking = true;
    linkMessage = '';
    try {
      const { suggestion } = await songLookup(accountId, { url });
      if (!current()) return;
      if (suggestion.title && !title.trim()) title = suggestion.title;
      if (suggestion.artist && !artist.trim()) artist = suggestion.artist;
      linkMessage = suggestion.message || '';
    } catch (e) {
      if (current()) linkMessage = `${e.message} You can type the title in.`;
    } finally {
      if (generation === lookupGeneration) linkLooking = false;
    }
  }

  function chooseAudio(event) {
    const file = event.currentTarget.files?.[0] || null;
    audioFile = file;
    error = file && file.size > maxBytes ? `${file.name} is ${formatBytes(file.size)}. The limit is ${maxLabel}.` : '';
    guess = file ? guessFromFilename(file.name) : { title: '', artist: '' };
  }

  function submit(event) {
    event.preventDefault();
    if (!hearable || tooLarge) return;
    error = '';
    const body = new FormData();
    if (editing) body.append('_method', 'patch');
    const kept = links.map((l) => l.trim()).filter(Boolean);
    if (kept.length) kept.forEach((l) => body.append('field_song[links][]', l));
    else body.append('field_song[links]', '');
    if (audioFile) body.append('field_song[audio]', audioFile);
    body.append('field_song[title]', title.trim());
    body.append('field_song[artist]', artist.trim());
    body.append('field_song[album]', album.trim());
    body.append('field_song[year]', year.trim());
    body.append('field_song[lyrics]', instrumental ? '' : lyrics);
    body.append('field_song[instrumental]', instrumental ? 'true' : 'false');
    body.append('field_song[note]', note.trim());
    body.append('field_song[shared_for]', sharedFor);
    body.append('field_song[dated_at]', date);
    saving = true;
    const url = editing ? `/accounts/${accountId}/field/songs/${song.id}` : `/accounts/${accountId}/field/songs`;
    router.post(url, body, {
      preserveState: true,
      preserveScroll: true,
      onSuccess: (page) => {
        const failed = page?.props?.errors?.song;
        if (failed) error = failed;
        else open = false;
      },
      onError: (errors) => (error = errors.song || 'Saving failed. Please try again.'),
      onFinish: () => (saving = false),
    });
  }
</script>

<Dialog.Root bind:open>
  <Dialog.Content class="sm:max-w-2xl max-h-[90vh] overflow-y-auto">
    <Dialog.Header>
      <Dialog.Title>{editing ? 'Edit the song' : 'Share a song'}</Dialog.Title>
      <Dialog.Description>
        {sharedLine}
        Looking up a title sends a YouTube or Spotify link to that service; Find lyrics sends the title and artist to LRCLIB
        (lrclib.net). The players load from Spotify or YouTube only when the song is opened.
      </Dialog.Description>
    </Dialog.Header>
    <form onsubmit={submit} class="space-y-4" data-testid="field-song-form">
      <fieldset class="space-y-2">
        <legend class="text-sm font-medium">Where to hear it</legend>
        {#each links as _, index (index)}
          <Input
            type="url"
            bind:value={links[index]}
            onblur={index === 0 ? lookUpLink : undefined}
            onpaste={index === 0 ? () => setTimeout(lookUpLink, 0) : undefined}
            placeholder={index === 0 ? 'Paste a Spotify, YouTube, Bandcamp… link' : 'Another link'}
            aria-label={index === 0 ? 'Link' : `Link ${index + 1}`}
            data-testid="field-song-link" />
        {/each}
        <div class="flex flex-wrap items-center gap-2">
          {#if links.length < MAX_LINKS}
            <Button type="button" variant="ghost" size="sm" onclick={() => (links = [...links, ''])}>
              <Plus class="size-4" /> Another link
            </Button>
          {/if}
          {#if linkLooking}<span class="text-xs text-muted-foreground">Looking up the link…</span>{/if}
          {#if linkMessage}<span class="text-xs text-muted-foreground" data-testid="field-song-link-message"
              >{linkMessage}</span
            >{/if}
        </div>
        <div class="space-y-1">
          <Label for="field-song-audio">
            {song?.audio ? `Replace the audio file (${song.audio.filename})` : 'Or an audio file'}
            <span class="text-muted-foreground">(mp3, m4a, ogg, wav, flac; up to {maxLabel})</span>
          </Label>
          <Input id="field-song-audio" type="file" accept="audio/*" onchange={chooseAudio} />
          <p class="text-xs text-muted-foreground">
            Leave the title, artist and album blank and they're read from the file's own tags, or failing that its name
            (shown greyed above).
          </p>
        </div>
        {#if !hearable}
          <p class="text-xs text-muted-foreground">A link or a file is needed, so the song can be heard.</p>
        {/if}
      </fieldset>

      <div class="grid gap-3 sm:grid-cols-2">
        <div class="space-y-1">
          <Label for="field-song-title">Title</Label>
          <Input
            id="field-song-title"
            bind:value={title}
            maxlength={200}
            required={!audioFile}
            placeholder={guess.title}
            data-testid="field-song-title" />
        </div>
        <div class="space-y-1">
          <Label for="field-song-artist">Artist</Label>
          <Input
            id="field-song-artist"
            bind:value={artist}
            maxlength={200}
            placeholder={guess.artist}
            data-testid="field-song-artist" />
        </div>
        <div class="space-y-1">
          <Label for="field-song-album">Album <span class="text-muted-foreground">(optional)</span></Label>
          <Input id="field-song-album" bind:value={album} maxlength={200} />
        </div>
        <div class="space-y-1">
          <Label for="field-song-year">Year <span class="text-muted-foreground">(optional)</span></Label>
          <Input id="field-song-year" bind:value={year} inputmode="numeric" maxlength={4} class="w-28" />
        </div>
      </div>

      {#key open}
        <FieldSongLyricsInput
          {accountId}
          bind:lyrics
          bind:instrumental
          title={title.trim() || guess.title}
          artist={artist.trim() || guess.artist}
          durationMs={song?.duration_ms}
          focus={open && focusLyrics} />
      {/key}

      <div class="space-y-1">
        <Label for="field-song-note">Why this song <span class="text-muted-foreground">(optional)</span></Label>
        <textarea
          id="field-song-note"
          bind:value={note}
          maxlength={2000}
          rows="3"
          class="w-full rounded-md border border-input bg-background px-3 py-2 text-sm"
          placeholder="We played this on the drive back from Girona."></textarea>
      </div>

      <div class="grid gap-3 sm:grid-cols-2">
        <div class="space-y-1">
          <Label for="field-song-for">For <span class="text-muted-foreground">(optional)</span></Label>
          <select
            id="field-song-for"
            bind:value={sharedFor}
            class="h-9 w-full rounded-md border border-input bg-background px-3 text-sm"
            data-testid="field-song-for">
            <option value="">Everyone here</option>
            {#each recipients as person (person.key)}
              <option value={person.key}>{person.name}</option>
            {/each}
          </select>
          <p class="text-xs text-muted-foreground">Says who it's for. Everyone in the account can still read it.</p>
        </div>
        <div class="space-y-1">
          <Label for="field-song-date"
            >When it came into it <span class="text-muted-foreground">(optional)</span></Label>
          <Input id="field-song-date" type="date" class="w-44" bind:value={date} />
        </div>
      </div>

      {#if error}
        <p class="text-sm text-destructive" role="alert">{error}</p>
      {/if}
      <Dialog.Footer>
        <Button type="button" variant="ghost" onclick={() => (open = false)}>Cancel</Button>
        <Button type="submit" disabled={!hearable || tooLarge || saving} data-testid="field-song-save">
          {saving ? 'Saving…' : editing ? 'Save' : 'Share in the Field'}
        </Button>
      </Dialog.Footer>
    </form>
  </Dialog.Content>
</Dialog.Root>
