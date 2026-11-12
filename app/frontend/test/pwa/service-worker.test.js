import { describe, it, expect, beforeEach, vi } from 'vitest';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

const SOURCE = readFileSync(resolve(__dirname, '../../../views/pwa/service-worker.js'), 'utf8');

// Load the real worker source against a fake ServiceWorkerGlobalScope.
function loadWorker({ cacheKeys = [], fetchImpl } = {}) {
  const listeners = {};
  const deleted = [];
  const store = new Map();
  const cache = {
    match: vi.fn(async (req) => store.get(req.url)),
    put: vi.fn(async (req, res) => store.set(req.url, res)),
  };
  const caches = {
    keys: vi.fn(async () => cacheKeys),
    delete: vi.fn(async (key) => {
      deleted.push(key);
      return true;
    }),
    open: vi.fn(async () => cache),
  };
  const self = {
    location: { origin: 'https://house.test' },
    addEventListener: (type, fn) => (listeners[type] = fn),
    skipWaiting: vi.fn(),
    clients: { claim: vi.fn(async () => {}) },
  };
  const fetch = vi.fn(fetchImpl || (async () => new Response('ok')));
  new Function('self', 'caches', 'fetch', 'Response', SOURCE)(self, caches, fetch, Response);
  return { listeners, deleted, caches, cache, fetch, self };
}

function fakeRequest(url, { mode = 'cors', method = 'GET', headers = {} } = {}) {
  return { url, mode, method, headers: new Headers(headers) };
}

async function dispatchFetch(worker, request) {
  let responded;
  worker.listeners.fetch({ request, respondWith: (p) => (responded = p) });
  return responded && (await responded);
}

describe('service worker lifecycle', () => {
  it('retires only older versions of its own shell cache', async () => {
    const worker = loadWorker({
      cacheKeys: ['app-shell-v0', 'app-shell-v1', 'someone-elses-cache', 'workbox-precache'],
    });
    let done;
    worker.listeners.activate({ waitUntil: (p) => (done = p) });
    await done;
    expect(worker.deleted).toEqual(['app-shell-v0']);
    expect(worker.self.clients.claim).toHaveBeenCalled();
  });
});

describe('service worker offline behaviour', () => {
  const offline = async () => {
    throw new TypeError('Failed to fetch');
  };

  it('shows the offline page for a failed document navigation', async () => {
    const worker = loadWorker({ fetchImpl: offline });
    const response = await dispatchFetch(worker, fakeRequest('https://house.test/chats/1', { mode: 'navigate' }));
    expect(response.status).toBe(503);
    const html = await response.text();
    expect(html).toContain("You're offline");
  });

  it('never claims that nothing was sent', async () => {
    const worker = loadWorker({ fetchImpl: offline });
    const response = await dispatchFetch(worker, fakeRequest('https://house.test/', { mode: 'navigate' }));
    const html = await response.text();
    expect(html).not.toMatch(/nothing you typed was sent/i);
    expect(html).toMatch(/check whether it arrived/i);
  });

  it('turns a failed Inertia visit into a full navigation that reaches the offline page', async () => {
    const worker = loadWorker({ fetchImpl: offline });
    const url = 'https://house.test/chats/2';
    const response = await dispatchFetch(worker, fakeRequest(url, { headers: { 'X-Inertia': 'true' } }));
    expect(response.status).toBe(409);
    expect(response.headers.get('X-Inertia-Location')).toBe(url);
  });

  it('passes successful Inertia visits through untouched', async () => {
    const worker = loadWorker();
    const response = await dispatchFetch(
      worker,
      fakeRequest('https://house.test/chats/3', { headers: { 'X-Inertia': 'true' } })
    );
    expect(await response.text()).toBe('ok');
  });

  it('leaves non-GET requests and other origins alone', async () => {
    const worker = loadWorker({ fetchImpl: offline });
    expect(await dispatchFetch(worker, fakeRequest('https://house.test/messages', { method: 'POST' }))).toBeUndefined();
    expect(await dispatchFetch(worker, fakeRequest('https://elsewhere.test/', { mode: 'navigate' }))).toBeUndefined();
  });

  it('caches only fingerprinted build assets, never API data', async () => {
    // Same-origin network responses are type 'basic'; a constructed Response is not.
    const sameOrigin = async () => Object.defineProperty(new Response('asset'), 'type', { value: 'basic' });
    const worker = loadWorker({ fetchImpl: sameOrigin });
    await dispatchFetch(worker, fakeRequest('https://house.test/vite/assets/app-abc123.js'));
    expect(worker.cache.put).toHaveBeenCalledTimes(1);
    expect(await dispatchFetch(worker, fakeRequest('https://house.test/api/v1/conversations'))).toBeUndefined();
    expect(worker.cache.put).toHaveBeenCalledTimes(1);
  });
});
