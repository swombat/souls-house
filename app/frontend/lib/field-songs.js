// Songs in the Field: pure helpers for the dialog, the viewer and the list.
// Kept free of Svelte so they can be unit tested.

const SPOTIFY_EMBED = /^(track|album|playlist|episode)\/[A-Za-z0-9]{10,40}$/;
const YOUTUBE_ID = /^[A-Za-z0-9_-]{11}$/;

// The player for a link, built only from the id the server parsed out of it
// (never the address itself). null when the provider has no embed here.
export function embedUrl(link) {
  if (!link?.embed_id) return null;
  if (link.provider === 'spotify' && SPOTIFY_EMBED.test(link.embed_id)) {
    return `https://open.spotify.com/embed/${link.embed_id}`;
  }
  if (link.provider === 'youtube' && YOUTUBE_ID.test(link.embed_id)) {
    return `https://www.youtube-nocookie.com/embed/${link.embed_id}`;
  }
  return null;
}

// Height of the player for a link: Spotify's compact track card, a 16:9 video.
export function embedHeight(link) {
  if (link?.provider === 'spotify') return link.embed_id?.startsWith('track/') ? 152 : 352;
  return null;
}

// Lyrics as verse: stanzas separated by blank lines, each a list of lines.
export function stanzas(lyrics) {
  if (!lyrics || !lyrics.trim()) return [];
  return lyrics
    .replace(/\r\n?/g, '\n')
    .trim()
    .split(/\n[ \t]*\n+/)
    .map((stanza) => stanza.split('\n'));
}

// What to do with a lookup's lyrics given what is already in the box:
// 'fill' an empty box, 'same' if they are already there, otherwise 'confirm'
// (never overwrite words someone typed without asking).
export function lyricsChoice(current, candidate) {
  const typed = (current || '').trim();
  const offered = (candidate || '').trim();
  if (!typed) return 'fill';
  if (typed === offered) return 'same';
  return 'confirm';
}

// "Jeff Buckley - Hallelujah.mp3" => { artist, title }; the whole name as the
// title when there's no dash.
export function guessFromFilename(name) {
  const base = (name || '')
    .replace(/\.[^.]+$/, '')
    .replace(/_/g, ' ')
    .replace(/^\d{1,3}[\s.-]+/, '')
    .trim();
  const parts = base.split(/\s+[-–—]\s+/);
  if (parts.length >= 2 && parts[0] && parts[1]) return { artist: parts[0], title: parts.slice(1).join(' - ') };
  return { artist: '', title: base };
}

// "Jeff Buckley · Grace · 1994"
export function songByline(song) {
  return [song?.artist, song?.album, song?.year].filter(Boolean).join(' · ');
}

// "Shared by Daniel for Lume", "Shared by Mira"
export function sharedBy(song) {
  if (!song?.added_by_name) return song?.shared_for_name ? `For ${song.shared_for_name}` : '';
  return song.shared_for_name
    ? `Shared by ${song.added_by_name} for ${song.shared_for_name}`
    : `Shared by ${song.added_by_name}`;
}

export function formatSeconds(seconds) {
  if (seconds == null) return '';
  const s = Math.round(seconds);
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;
}

export const LYRICS_LABELS = {
  missing: 'No lyrics yet',
  instrumental: 'Instrumental',
  present: null,
};

// The page's lookup endpoint: { suggestion } for { url }, { candidates } for
// { title, artist }. Throws with the server's message when it fails.
export async function songLookup(accountId, params) {
  const response = await fetch(`/accounts/${accountId}/field/songs/lookup?${new URLSearchParams(params)}`, {
    headers: { Accept: 'application/json' },
  });
  let data = {};
  try {
    data = await response.json();
  } catch {
    // An answer that isn't JSON is a failure like any other.
  }
  if (!response.ok) throw new Error(data.error || 'The lookup failed');
  return data;
}
