import { defineConfig, devices } from '@playwright/test';

import { instance } from './playwright/instance.js';
const baseURL = instance.playwright_url;

export default defineConfig({
  testDir: './test/e2e',
  timeout: 45_000,
  expect: {
    timeout: 10_000,
  },
  fullyParallel: false,
  retries: process.env.CI ? 1 : 0,
  reporter: [['list'], ['html', { outputFolder: 'playwright-report/e2e', open: 'never' }]],
  use: {
    baseURL,
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
    video: 'retain-on-failure',
  },
  projects: [
    {
      name: 'chromium',
      testIgnore: '**/account_capacity.spec.js',
      use: { ...devices['Desktop Chrome'] },
    },
    {
      name: 'admission',
      testMatch: '**/account_capacity.spec.js',
      dependencies: ['chromium'],
      use: { ...devices['Desktop Chrome'] },
    },
  ],
});
