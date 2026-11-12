// Installable app service worker: app shell only.
//
// It caches fingerprinted build assets (/vite/assets/*, immutable by name) so the
// installed app opens fast, and shows a small offline page when a navigation
// fails. It never stores pages, API responses, uploads or anything private, and
// never touches non-GET requests or the Action Cable socket: every conversation
// is always read live from the server.

const SHELL_CACHE_PREFIX = 'app-shell-';
const SHELL_CACHE = `${SHELL_CACHE_PREFIX}v1`;
const ASSET_PATH = /^\/vite\/assets\//;

// A failed page load cannot tell whether an earlier send reached the server, so
// the copy says what we know (no connection now) and nothing about past sends.
const OFFLINE_HTML = `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Offline</title>
<style>
  :root { color-scheme: light dark; }
  body { margin: 0; min-height: 100dvh; display: grid; place-items: center;
         font: 16px/1.5 system-ui, sans-serif; background: Canvas; color: CanvasText; }
  main { max-width: 22rem; padding: 2rem; text-align: center; }
  button { min-height: 44px; padding: 0 1.25rem; border: 0; border-radius: 0.625rem;
           background: #307c85; color: #fff; font: inherit; font-weight: 600; }
</style></head><body><main>
<h1>You're offline</h1>
<p>This page needs a connection to show your conversations.</p>
<p>If you sent something just before the connection dropped, open the conversation again once you're back online to check whether it arrived.</p>
<button type="button" onclick="location.reload()">Try again</button>
</main></body></html>`;

function offlineResponse() {
  return new Response(OFFLINE_HTML, {
    status: 503,
    headers: { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' },
  });
}

// Inertia page visits are XHR GETs, not document navigations. When one fails
// offline, answer with Inertia's location-visit response (409 + X-Inertia-Location):
// Inertia then performs a full document navigation to the same URL, which fails
// too and lands on the offline page above instead of a silent dead click.
function inertiaOfflineResponse(request) {
  return new Response('', {
    status: 409,
    headers: { 'X-Inertia-Location': request.url, 'Cache-Control': 'no-store' },
  });
}

function isInertiaVisit(request) {
  return request.headers.get('X-Inertia') === 'true';
}

function isOwnShellCache(key) {
  return key.startsWith(SHELL_CACHE_PREFIX);
}

self.addEventListener('install', () => self.skipWaiting());

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches
      .keys()
      // Only retire older versions of our own shell cache; other caches on the
      // origin belong to someone else.
      .then((keys) =>
        Promise.all(keys.filter((key) => isOwnShellCache(key) && key !== SHELL_CACHE).map((key) => caches.delete(key)))
      )
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (event) => {
  const request = event.request;
  if (request.method !== 'GET') return;

  const url = new URL(request.url);
  if (url.origin !== self.location.origin) return;

  if (request.mode === 'navigate') {
    event.respondWith(fetch(request).catch(() => offlineResponse()));
    return;
  }

  if (isInertiaVisit(request)) {
    event.respondWith(fetch(request).catch(() => inertiaOfflineResponse(request)));
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
