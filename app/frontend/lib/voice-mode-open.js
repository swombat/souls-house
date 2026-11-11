import { writable } from 'svelte/store';

// Whether voice mode's panel is open on this page (VoiceModePanel sets it
// while mounted). Reading replies aloud from the header (lib/read-aloud.js)
// pauses while it is, so only one reader uses the one audio element.
export const voiceModeOpen = writable(false);
