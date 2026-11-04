import { loadPhonon, synthesize, phononState, voices } from '$lib/phonon-engine';
const log = (m) => { window.__log.push(m); };
window.__log = [];
phononState.subscribe((s) => log({ state: s.status, progress: s.progress, error: s.error, persisted: s.persisted }));
window.run = async (text, voice) => {
  const t0 = performance.now();
  await loadPhonon();
  const t1 = performance.now();
  const { blob, duration } = await synthesize(text, { voice });
  const t2 = performance.now();
  const keys = await (await caches.open('phonon-webgpu')).keys();
  return { loadMs: Math.round(t1 - t0), synthMs: Math.round(t2 - t1), audioSeconds: duration, wavBytes: blob.size,
    cacheKeys: keys.map((r) => new URL(r.url).pathname), adapter: !!navigator.gpu, voices: voices.length };
};
window.ready = true;
