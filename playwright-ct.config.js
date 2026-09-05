import { defineConfig, devices } from '@playwright/experimental-ct-svelte';
import { resolve } from 'path';
import { fileURLToPath } from 'url';

import { instance } from './playwright/instance.js';

const __dirname = fileURLToPath(new URL('.', import.meta.url));

export default defineConfig({
  testDir: './playwright/tests',
  testMatch: '**/*.pw.{js,jsx,ts,tsx}',

  // Shared settings for all projects
  use: {
    // Base URL for your Rails app
    baseURL: instance.playwright_url,

    // Capture traces for failed tests
    trace: 'on-first-retry',

    // Screenshots on failure
    screenshot: 'only-on-failure',

    // Video on failure
    video: 'retain-on-failure',

    // Component testing specific options
    ctPort: instance.ports.component, // Changed from 3100 to avoid conflict with Rails test server
    ctViteConfig: {
      resolve: {
        alias: {
          $lib: resolve(__dirname, 'app/frontend/lib'),
          '@': resolve(__dirname, 'app/frontend'),
          '@/routes': resolve(__dirname, 'playwright/test-routes.js'),
          '@inertiajs/svelte': resolve(__dirname, 'playwright/test-inertia-adapter.js'),
        },
      },
      server: {
        proxy: {
          '/login': instance.playwright_url,
          '/signup': instance.playwright_url,
          '/logout': instance.playwright_url,
          '/passwords': instance.playwright_url,
          '/password': instance.playwright_url,
          '/session': instance.playwright_url,
        },
      },
    },
  },

  // Configure projects for cross-browser testing
  projects: [
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'] },
    },
  ],

  // Folder for test artifacts
  outputDir: 'test-results/',

  // Reporter configuration
  reporter: [['html', { outputFolder: 'playwright-report', open: 'never' }], ['list']],

  // Run tests in parallel
  fullyParallel: true,

  // Retry failed tests
  retries: process.env.CI ? 2 : 0,

  // Limit workers on CI
  workers: process.env.CI ? 1 : undefined,
});
