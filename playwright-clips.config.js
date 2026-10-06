import { defineConfig, devices } from '@playwright/experimental-ct-svelte';
import { resolve } from 'path';
import { fileURLToPath } from 'url';
import tailwindcss from '@tailwindcss/vite';
import { svelte } from '@sveltejs/vite-plugin-svelte';

// Feature clips for the /features page: real components rendered frame by frame, encoded with ffmpeg.
// No Rails backend needed. Run: bun run clips  (one clip: bun run clips -g soul-seed)
const __dirname = fileURLToPath(new URL('.', import.meta.url));

export default defineConfig({
  testDir: './playwright/clips',
  testMatch: '**/*.clip.js',
  timeout: 15 * 60 * 1000,
  workers: 1,
  use: {
    ...devices['Desktop Chrome'],
    locale: 'en-GB',
    timezoneId: 'Europe/Madrid',
    ctPort: Number(process.env.CLIPS_CT_PORT || 3297),
    ctCacheDir: 'tmp/clips-ct-cache',
    ctViteConfig: {
      plugins: [svelte(), tailwindcss()],
      resolve: {
        alias: {
          $lib: resolve(__dirname, 'app/frontend/lib'),
          '@': resolve(__dirname, 'app/frontend'),
          '@/routes': resolve(__dirname, 'playwright/test-routes.js'),
          '@inertiajs/svelte': resolve(__dirname, 'playwright/test-inertia-adapter.js'),
        },
      },
    },
  },
});
