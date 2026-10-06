import { mkdirSync, rmSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { resolve } from 'node:path';

// Renders a clip component frame by frame. `t` (seconds) is a prop, so every frame is set
// explicitly rather than recorded in real time. Output: public/feature-clips/<name>.{mp4,jpg}
// (H.264 only: it plays everywhere, and VP9 came out larger at matching quality.).
// CLIP_FRAMES=12,90,200 renders only those frames as PNGs (for checking stills) and skips encoding.
export async function renderClip({ mount, page, Component, name, duration, fps = 30, poster = null }) {
  await page.setViewportSize({ width: 1280, height: 720 });
  const frames = resolve(process.cwd(), 'tmp/clips', name);
  const out = resolve(process.cwd(), 'public/feature-clips');
  const only = process.env.CLIP_FRAMES ? process.env.CLIP_FRAMES.split(',').map(Number) : null;
  rmSync(frames, { recursive: true, force: true });
  mkdirSync(frames, { recursive: true });
  mkdirSync(out, { recursive: true });

  const component = await mount(Component, { props: { t: 0 } });
  const stage = page.locator('.clip-stage');
  await page.evaluate(() => document.fonts.ready);

  const total = Math.round(duration * fps);
  for (const i of only ?? [...Array(total).keys()]) {
    await component.update({ props: { t: i / fps } });
    await page.evaluate(() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r))));
    await stage.screenshot({ path: `${frames}/${String(i).padStart(4, '0')}.png`, animations: 'disabled' });
  }
  if (only) return;

  const input = ['-y', '-loglevel', 'error', '-framerate', String(fps), '-i', `${frames}/%04d.png`];
  execFileSync('ffmpeg', [
    ...input,
    '-c:v',
    'libx264',
    '-pix_fmt',
    'yuv420p',
    '-crf',
    '24',
    '-preset',
    'slow',
    '-movflags',
    '+faststart',
    '-an',
    `${out}/${name}.mp4`,
  ]);
  const posterFrame = String(poster ?? Math.round(total * 0.8)).padStart(4, '0');
  execFileSync('ffmpeg', [
    '-y',
    '-loglevel',
    'error',
    '-i',
    `${frames}/${posterFrame}.png`,
    '-q:v',
    '4',
    `${out}/${name}.jpg`,
  ]);
}
