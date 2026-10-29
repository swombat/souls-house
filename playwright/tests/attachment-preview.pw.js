import { test, expect } from '@playwright/experimental-ct-svelte';
import CommitBadgeHarness from '../CommitBadgeHarness.svelte';

const proxy = (name) => `/rails/active_storage/blobs/proxy/sig/${name}?disposition=inline`;
const blob = (name) => `/rails/active_storage/blobs/redirect/sig/${name}?disposition=attachment`;

const messages = [
  {
    id: 'mira-1',
    role: 'assistant',
    author_name: 'Mira',
    content: 'Full scores are attached.',
    created_at: '2026-10-29T12:46:00Z',
    files_json: [
      {
        id: 1,
        filename: 'comparison.md',
        content_type: 'text/markdown',
        byte_size: 2048,
        url: blob('comparison.md'),
        inline_url: proxy('comparison.md'),
      },
      {
        id: 2,
        filename: 'evidence.zip',
        content_type: 'application/zip',
        byte_size: 54272,
        url: blob('evidence.zip'),
        inline_url: proxy('evidence.zip'),
      },
      {
        id: 3,
        filename: 'recording.webm',
        content_type: 'audio/webm',
        byte_size: 343225,
        url: blob('recording.webm'),
        inline_url: proxy('recording.webm'),
      },
    ],
  },
];

test('a markdown attachment opens rendered in place, a zip has no eye', async ({ mount, page }) => {
  await page.route('**/commit_statuses**', (route) =>
    route.fulfill({ status: 200, contentType: 'application/json', body: '{"statuses":{}}' })
  );
  await page.route('**/blobs/proxy/sig/comparison.md**', (route) =>
    route.fulfill({
      status: 200,
      contentType: 'text/markdown',
      body: '# Comparison\n\n| Model | Score |\n| --- | --- |\n| Nemotron | 8.1 |\n\n**Bold** finding.',
    })
  );

  const component = await mount(CommitBadgeHarness, { props: { messages, repos: [] } });

  const chips = component.locator('[data-testid="file-attachment"]');
  await expect(chips).toHaveCount(3);
  await expect(chips.nth(0).locator('[data-testid="file-attachment-preview"]')).toHaveCount(1);
  await expect(chips.nth(1).locator('[data-testid="file-attachment-preview"]')).toHaveCount(0);
  await expect(chips.nth(2).locator('[data-testid="file-attachment-preview"]')).toHaveCount(1);

  // The filename is still a download link.
  await expect(chips.nth(0).locator('a')).toHaveAttribute('download', 'comparison.md');

  await chips.nth(0).locator('[data-testid="file-attachment-preview"]').click();
  const dialog = page.locator('[data-testid="attachment-preview"]');
  await expect(dialog).toBeVisible();
  await expect(dialog).toHaveAttribute('data-preview-kind', 'markdown');
  await expect(dialog.locator('h1')).toHaveText('Comparison');
  await expect(dialog.locator('table')).toContainText('Nemotron');
  await expect(dialog.locator('strong')).toHaveText('Bold');
  await page.screenshot({ path: 'tmp/attachment-preview-markdown.png' });

  await page.keyboard.press('Escape');
  await expect(dialog).toHaveCount(0);

  await chips.nth(2).locator('[data-testid="file-attachment-preview"]').click();
  const audio = page.locator('[data-testid="attachment-preview-audio"]');
  await expect(audio).toHaveAttribute('src', proxy('recording.webm'));
  await expect(audio).toHaveAttribute('controls', '');
});
