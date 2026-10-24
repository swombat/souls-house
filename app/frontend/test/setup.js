import '@testing-library/jest-dom/vitest';
import { cleanup } from '@testing-library/svelte';
import { afterAll, afterEach, vi } from 'vitest';

// Cleanup after each test
afterEach(() => {
  cleanup();
  vi.clearAllMocks();
});

// bits-ui components that lock page scroll (Dialog, Popover, etc.) register a
// `window.setTimeout` in node_modules/bits-ui/dist/internal/body-scroll-lock.svelte.js
// that resets `document.body`'s style ~24ms after the last lock unmounts, to allow
// for same-tick close/reopen. That's a real timer running on the Node event loop, not
// something `cleanup()` or fake timers can flush. If a test opens and closes such a
// component, the timer can still be pending when this file's tests finish, and Vitest
// tears down jsdom right after this file's hooks run. The timer then fires against a
// torn-down `document`, throwing "ReferenceError: document is not defined" as an
// unhandled error "caught after test environment was torn down" — only when the 24ms
// window loses the race with teardown, hence the flake. Give it a real moment to run
// against a still-live `document` before the environment goes away.
afterAll(async () => {
  await new Promise((resolve) => setTimeout(resolve, 50));
});

// Mock window.matchMedia for responsive tests
Object.defineProperty(window, 'matchMedia', {
  writable: true,
  value: vi.fn().mockImplementation((query) => ({
    matches: false,
    media: query,
    onchange: null,
    addListener: vi.fn(),
    removeListener: vi.fn(),
    addEventListener: vi.fn(),
    removeEventListener: vi.fn(),
    dispatchEvent: vi.fn(),
  })),
});

// Mock IntersectionObserver
global.IntersectionObserver = vi.fn().mockImplementation(() => ({
  observe: vi.fn(),
  unobserve: vi.fn(),
  disconnect: vi.fn(),
}));

// Mock ResizeObserver
global.ResizeObserver = vi.fn().mockImplementation(() => ({
  observe: vi.fn(),
  unobserve: vi.fn(),
  disconnect: vi.fn(),
}));
