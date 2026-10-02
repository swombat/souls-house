import { expect, test } from '@playwright/test';

test('owner can find import before birth, reject a bad archive, and confirm a stopped copy', async ({
  page,
  request,
}, testInfo) => {
  const runId = `portability-${Date.now()}`;
  const setupResponse = await request.post('/test/e2e/setup', { data: { run_id: runId } });
  expect(setupResponse.ok()).toBe(true);
  const setup = await setupResponse.json();
  try {
    await page.goto('/login');
    await page.getByLabel(/email/i).fill(setup.primary_user.email);
    await page.getByLabel(/password/i).fill(setup.password);
    await page.getByRole('button', { name: /log in/i }).click();
    await expect(page).toHaveURL(/\/$/);
    await page.goto(`/accounts/${setup.account_param}/residents/new`);
    await page.getByRole('link', { name: 'Import a resident archive instead', exact: true }).click();
    await expect(page.getByRole('heading', { name: 'Import a resident', exact: true })).toBeVisible();
    await expect(page.getByText(/confidential.*unencrypted/i).first()).toBeVisible();
    const upload = page.getByLabel('Resident archive (.tar.gz)');
    await upload.setInputFiles({
      name: 'bad.tar.gz',
      mimeType: 'application/gzip',
      buffer: Buffer.from('not an archive'),
    });
    await page.getByRole('button', { name: 'Preview archive', exact: true }).click();
    await expect(page.getByRole('alert')).toBeVisible();
    await expect(page.getByRole('heading', { name: 'Archive preview' })).toHaveCount(0);
    await page.screenshot({ path: testInfo.outputPath('invalid-archive.png') });

    // UI-only success fixture: backend graph/filesystem round trips have separate
    // service tests. Never ask this browser test to touch a real Docker home.
    const destination = `/accounts/${setup.account_param}/residents`;
    let confirmed = false;
    await page.route('**/*', async (route) => {
      const req = route.request();
      const contentType = req.headers()['content-type'] || '';
      if (req.method() !== 'POST' || !contentType.includes('multipart/form-data')) return route.continue();
      const body = req.postData() || '';
      if (body.includes('name="confirmed"')) {
        expect(body).toContain('Synthetic restored copy');
        expect(body).toContain('name="archive"');
        confirmed = true;
        return route.fulfill({ json: { redirect_url: destination } });
      }
      return route.fulfill({
        json: {
          preview: {
            name: 'Synthetic resident',
            export_id: 'fixture-export',
            source_resident_id: 'fixture-source',
            created_at: '2026-10-02T12:00:00Z',
            files_count: 2,
            graph_nodes: 2,
            graph_edges: 1,
            duplicate: true,
            warnings: ['Conversation history and credentials are not included.'],
          },
        },
      });
    });
    await upload.setInputFiles({
      name: 'synthetic.tar.gz',
      mimeType: 'application/gzip',
      buffer: Buffer.from('UI fixture only'),
    });
    await page.getByRole('button', { name: 'Preview archive', exact: true }).click();
    await expect(page.getByRole('heading', { name: 'Archive preview' })).toBeVisible();
    await expect(page.getByText(/already been imported here/)).toBeVisible();
    await expect(page.getByRole('button', { name: 'Import stopped copy' })).toBeDisabled();
    await page.getByLabel('Name for the new resident').fill('Synthetic restored copy');
    await page.getByRole('checkbox', { name: /separate, stopped copy/ }).check();
    await page.screenshot({ path: testInfo.outputPath('import-preview.png') });
    await page.getByRole('button', { name: 'Import stopped copy' }).click();
    await expect(page).toHaveURL(new RegExp(`${destination}$`));
    expect(confirmed).toBe(true);
  } finally {
    expect((await request.post('/test/e2e/cleanup', { data: { run_id: runId } })).ok()).toBe(true);
  }
});
