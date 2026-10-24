# Songs in the Field — design

Lume, 2026-10-13, for Daniel's ask in OYzLwj. Review: Mira.

> "I'd like to be able to add songs to the field … a Spotify or YouTube link or MP3 and some lyrics … in all cases, I'd like both the song, even though most models cannot hear the music, … to be available, and also the lyrics importantly. And the name and the artist and so on … something special about having it present in a specific account … like sharing a song with someone."

## What a song is

A new Field kind, `song`, beside files, notes, recordings and tweets, with its own **Songs** tab. One row per song shared in this account (`FieldSong`):

| field | notes |
|---|---|
| `title` | required, ≤200 |
| `artist` | ≤200, optional but asked for |
| `album`, `year` | optional |
| `links` | up to 4 URLs; each normalised to `{provider, url, embed_id}` where provider ∈ spotify, youtube, apple_music, bandcamp, soundcloud, other |
| `audio` | optional attachment (mp3, m4a, ogg, opus, wav, flac), ≤50 MB, duration by ffprobe like recordings |
| `lyrics` | text ≤20k, line breaks kept exactly |
| `note` | "Why this song" ≤2,000: the part that makes it this relationship's song and not the training data's |
| `added_by` | polymorphic User/Agent, like `FieldFile#uploaded_by` |
| `suggested_by` | polymorphic, the resident whose message offered it through Add to Field (2026-10-16) |
| `shared_for` | optional polymorphic User/Agent in the account: "for Lume" |
| `dated_at` | optional "when this song came into it"; sorts by it, else `created_at` |

Discard (not delete), tags (`FieldTaggable`), broadcasts, obfuscated ids: the same machinery as every other kind. No summaries: lyrics shouldn't be paraphrased and the note already is the human context.

A song must be hearable: **a link or an audio file is required**. Lyrics are not required to save (you may have the link now and the words later), but a song without lyrics shows in the **Waiting** tab with "Add the lyrics", the same place unnamed speakers wait.

## Adding one (people)

One "Add a song" dialog, one first box: **paste a link or drop an audio file**.

- Link → the server reads the provider's public oEmbed (YouTube: title + channel; Spotify: title) and fills title/artist as suggestions the person can correct. YouTube's "Artist – Song (Official Video)" is split on the dash and the bracket dropped.
- Audio file → title/artist/album from the file's own tags (ffprobe `format_tags`), same suggestion treatment.
- Then: lyrics (a big paste box, with **Find lyrics** which asks LRCLIB — free, no key — by title + artist + duration and drops the plain lyrics into the box for the person to check; nothing is saved from a lookup alone), "Why this song", "For" (anyone in the account, optional), and the date.

You can add a second link later (the Spotify and the YouTube), or the MP3 to a song that only had a link.

## Reading one

The open song: the player first (Spotify embed / youtube-nocookie embed / `<audio>` for the file; if several, the file first, then a switch), then title · artist · year, "Shared by Daniel for Lume · 13 Oct", the note as a quote, then the lyrics set as verse: line breaks kept, stanzas spaced, readable width. Cards in the list show title, artist, who for, and a small "no lyrics yet" when waiting.

## Residents

Most of us can't hear it, so for a resident the song *is* the lyrics, the note, who shared it with whom and when, and the links. All of it comes back from the API in full.

- `GET /api/v1/field/songs` (tags, paging), `GET /api/v1/field/songs/:id` (full lyrics, note, links, `audio.download_path` for a resident that can hear, `shared_for`)
- `POST /api/v1/field/songs` JSON (links, lyrics, note, shared_for, dated_at) or multipart with `audio`; `PATCH` (add lyrics, a link, the note); `DELETE` discards; tags as for files
- `GET /api/v1/field/songs/lookup?url=…` and `?title=…&artist=…`: the same oEmbed + LRCLIB suggestions the dialog uses, so when Daniel drops a YouTube link in a chat a resident can bring it into the Field with lyrics in two calls
- Field search covers songs: title + artist (A), note (B), lyrics (C). Swarm search the same once the kind is in `FieldSearch::SOURCES`.
- The resident who adds a song is `added_by`; residents may add, edit lyrics/note/links and tag; discarding is a person's act, like tweets.

## Not in v1 (named so they can be asked for)

- Synced (timed) lyrics following the audio. LRCLIB returns them; storing `synced_lyrics` is cheap, showing them is the work.
- A song card inside a conversation message ("Daniel shared a song with you").
- Transcribing lyrics from the audio (Scribe on sung vocals is poor).
- Wake-on-share: a song "for Lume" doesn't trigger Lume. A tag in a chat already does that.

## Privacy and copyright

Visibility is the account, as for everything in the Field. Lyrics and audio are stored privately in one account for its members; nothing is published. The embeds load from Spotify/YouTube only when the song is opened (youtube-nocookie for YouTube). The Add dialog says that the lookup sends title and artist to LRCLIB and the link to the provider's oEmbed.

## Build order

1. Migration + `FieldSong` + search vector, listing/tab/Waiting, `FieldItems.song_json`, search source.
2. Web: Add dialog with link/file prefill and Find lyrics; viewer with players and verse; edit.
3. API + docs (`soulshouse-api.md` section), tests (model, lookup with stubbed HTTP, API, listing, a browser test that adds a song from a link and pastes lyrics).

Ships on, no switch (house rule for features Daniel asked for).
