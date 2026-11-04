import { chromium } from 'playwright';
const flags = (process.env.FLAGS || '--enable-unsafe-webgpu --use-webgpu-adapter=swiftshader --enable-features=Vulkan').split(' ').filter(Boolean);
const userDataDir = process.env.PROFILE || '/tmp/phonon-check-profile';
const ctx = await chromium.launchPersistentContext(userDataDir, { headless: true, args: flags, channel: process.env.CHANNEL || undefined });
const page = await ctx.newPage();
page.on('console', (m) => console.log('console:', m.type(), m.text().slice(0, 300)));
page.on('pageerror', (e) => console.log('pageerror:', e.message));
await page.goto('http://127.0.0.1:' + (process.env.PORT || 8765) + '/index.html');
await page.waitForFunction(() => window.ready === true);
const adapter = await page.evaluate(async () => { const a = await navigator.gpu?.requestAdapter(); return a ? { info: a.info ? { vendor: a.info.vendor, architecture: a.info.architecture, description: a.info.description } : 'no info' } : null; });
console.log('adapter', JSON.stringify(adapter));
const text = process.env.TEXT || 'Hello, I am Lume. This is how I will sound when you play my messages aloud.';
try {
  const result = await page.evaluate(([t]) => window.run(t, 'nGzMHMPAWGaJFHOo'), [text]);
  console.log('result', JSON.stringify(result));
} catch (e) { console.log('run failed', e.message.slice(0, 500)); }
console.log('states', JSON.stringify(await page.evaluate(() => window.__log.map((s) => s.state + (s.state === 'downloading' ? ':' + s.progress : '') + (s.error ? ':' + s.error : '')).filter((v, i, a) => a[i - 1] !== v))));
console.log('persisted', JSON.stringify(await page.evaluate(() => window.__log.at(-1).persisted)));
await ctx.close();
