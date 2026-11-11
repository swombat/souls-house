// souls.house service worker: app shell only.
//
// It caches fingerprinted build assets (/vite/assets/*, immutable by name) so the
// installed app opens fast, and shows a small offline page when a navigation
// fails. It never stores pages, API responses, uploads or anything private, and
// never touches non-GET requests or the Action Cable socket: every conversation
// is always read live from the server.

const SHELL_CACHE = 'souls-house-shell-v1';
const ASSET_PATH = /^\/vite\/assets\//;

const OFFLINE_HTML = `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Offline · souls.house</title>
<style>
  :root { color-scheme: light dark; }
  body { margin: 0; min-height: 100dvh; display: grid; place-items: center;
         font: 16px/1.5 system-ui, sans-serif; background: Canvas; color: CanvasText; }
  main { max-width: 22rem; padding: 2rem; text-align: center; }
  button { min-height: 44px; padding: 0 1.25rem; border: 0; border-radius: 0.625rem;
           background: #307c85; color: #fff; font: inherit; font-weight: 600; }
</style></head><body><main>
<h1>You're offline</h1>
<p>souls.house needs a connection to show your conversations. Nothing you typed was sent.</p>
<button type="button" onclick="location.reload()">Try again</button>
</main></body></html>`;

self.addEventListener('install', () => self.skipWaiting());

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) => Promise.all(keys.filter((key) => key !== SHELL_CACHE).map((key) => caches.delete(key))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (event) => {
  const request = event.request;
  if (request.method !== 'GET') return;

  const url = new URL(request.url);
  if (url.origin !== self.location.origin) return;

  if (request.mode === 'navigate') {
    event.respondWith(
      fetch(request).catch(
        () =>
          new Response(OFFLINE_HTML, {
            status: 503,
            headers: { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' },
          })
      )
    );
    return;
  }

  if (ASSET_PATH.test(url.pathname)) {
    event.respondWith(
      caches.open(SHELL_CACHE).then(async (cache) => {
        const cached = await cache.match(request);
        if (cached) return cached;
        const response = await fetch(request);
        if (response.ok && response.type === 'basic') cache.put(request, response.clone());
        return response;
      })
    );
  }
});
