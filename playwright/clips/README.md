# Feature clips

The short looping videos on `/features` are rendered from Svelte components, frame by frame. There is no screen
recording, so a clip comes out the same on every run, and re-rendering after a UI change keeps it current.

## How it works

- Each clip is a Svelte component (`*Clip.svelte`) whose whole picture is a pure function of one prop, `t`, the time
  in seconds. Helpers for timing live in `timeline.js` (`ramp`, `ease`, `typed`, `arrive`, `loopFade`).
- Where the clip shows real UI, it mounts the real component (for example `soul-seed-step.svelte`,
  `telegram-settings.svelte`, `RhythmCard.svelte`, `MessageBubble.svelte`) with fixture data. Clips about ideas
  rather than screens (associative recall, journals, heartbeats) are drawn directly.
- `render.js` mounts the clip through Playwright's component-test runner (the same Vite and Tailwind setup as
  `playwright-ct.config.js`, with the Inertia stub). For every frame it sets `t`, waits two animation frames, and
  screenshots the 1280×720 `.clip-stage`. ffmpeg then encodes `public/feature-clips/<name>.mp4` (H.264, 30 fps,
  `+faststart`) and takes `<name>.jpg` from one second before the end as the poster.
- `feature-list.js` points a card at a clip with `media: { kind: 'video', src, poster, alt }`. `FeatureShowcase`
  plays it muted, looped and inline, and shows the poster with controls instead when the visitor prefers reduced
  motion.

No Rails backend is needed.

## Running

```sh
bun run clips                      # every clip
bun run clips -g telegram          # one clip, by test name
CLIP_FRAMES=30,150,300 bun run clips -g recall   # stills only, written to tmp/clips/recall/, no encoding
```

Check stills before a full render. Contact-sheet them with ffmpeg
(`ffmpeg -pattern_type glob -i 'tmp/clips/recall/*.png' -vf "scale=640:-1,tile=2x4" sheet.png`) and look at them
at roughly the size the card shows (about 560 px wide on desktop). Text under about 18 px at 1280 wide is
unreadable on the page.

## Requirements and gotchas

- **ffmpeg with libx264** on `PATH`.
- **Fonts come from the rendering machine.** The clips ask for Inter and fall back to the system sans. On a bare
  Linux box with no sans font installed, everything renders in a monospace fallback, so install Inter (or similar)
  first. The terminal clip asks for Source Code Pro.
- **Playwright's bundled Chromium cannot play H.264.** Rendering is unaffected, because it only takes screenshots.
  But a headless check of `/features` will show the poster and never play the video. Real Chrome, Safari and
  Firefox play it.
- Times in clips are rendered in `en-GB` / `Europe/Madrid`, pinned in `playwright-clips.config.js`.
- Don't write the site's name literally in a clip; use `$siteName` from `$lib/branding`. The identity-leak test
  rejects the literal outside its allowlist, and self-hosters get their own name in re-rendered clips.
- Dynamic Tailwind classes (`bg-${colour}-100`) only exist if the class string appears somewhere in a scanned file.
  The clips mention the ones they need in a comment.

## Adding a clip

1. Write `playwright/clips/<Name>Clip.svelte` taking `t`. Use `loopFade(t, DURATION)` on the outer layer, so the
   loop seam is a soft fade.
2. Add it to a `*.clip.js` list with its name and duration.
3. Render stills, look, adjust, then render it fully.
4. Add `media` to the entry in `feature-list.js`, and the name to the clip list in `test/e2e/features_page.spec.js`.
