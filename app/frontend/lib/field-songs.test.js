import { describe, expect, it } from 'vitest';
import { embedUrl, formatSeconds, guessFromFilename, lyricsChoice, sharedBy, songByline, stanzas } from './field-songs';

describe('field songs', () => {
  it('builds players only from parsed ids', () => {
    expect(embedUrl({ provider: 'youtube', embed_id: 'y8AWFf7EAc4' })).toBe(
      'https://www.youtube-nocookie.com/embed/y8AWFf7EAc4'
    );
    expect(embedUrl({ provider: 'spotify', embed_id: 'track/3pRaLNL3b8x5uBOcsgvdqM' })).toBe(
      'https://open.spotify.com/embed/track/3pRaLNL3b8x5uBOcsgvdqM'
    );
    expect(embedUrl({ provider: 'youtube', embed_id: '"><script>' })).toBeNull();
    expect(embedUrl({ provider: 'bandcamp', embed_id: null })).toBeNull();
  });

  it('sets lyrics as stanzas with their lines kept', () => {
    expect(stanzas('a\nb\n\n\nc\r\nd')).toEqual([
      ['a', 'b'],
      ['c', 'd'],
    ]);
    expect(stanzas('  ')).toEqual([]);
  });

  it('never overwrites typed words without asking', () => {
    expect(lyricsChoice('', 'found words')).toBe('fill');
    expect(lyricsChoice('  \n', 'found words')).toBe('fill');
    expect(lyricsChoice('my own words', 'found words')).toBe('confirm');
    expect(lyricsChoice('found words\n', 'found words')).toBe('same');
  });

  it('guesses title and artist from a file name', () => {
    expect(guessFromFilename('03 - Jeff Buckley - Hallelujah.mp3')).toEqual({
      artist: 'Jeff Buckley',
      title: 'Hallelujah',
    });
    expect(guessFromFilename('clair_de_lune.flac')).toEqual({ artist: '', title: 'clair de lune' });
  });

  it('says who shared it with whom', () => {
    expect(sharedBy({ added_by_name: 'Daniel', shared_for_name: 'Lume' })).toBe('Shared by Daniel for Lume');
    expect(sharedBy({ added_by_name: 'Mira' })).toBe('Shared by Mira');
    expect(songByline({ artist: 'Jeff Buckley', year: 1994 })).toBe('Jeff Buckley · 1994');
    expect(formatSeconds(413)).toBe('6:53');
  });
});
