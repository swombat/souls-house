import { expect, test } from '@playwright/test';

test.use({ viewport: { width: 360, height: 740 }, colorScheme: 'dark' });

test.describe('mobile chat layout', () => {
  let setup;

  test.beforeEach(async ({ page, request }) => {
    const runId = `mobile-${Date.now()}-${Math.random().toString(36).slice(2)}`;
    const response = await request.post('/test/e2e/setup', { data: { run_id: runId } });
    expect(response.ok()).toBe(true);
    setup = await response.json();
    await page.goto('/login');
    await page.getByLabel(/email/i).fill(setup.primary_user.email);
    await page.getByLabel(/password/i).fill(setup.password);
    await page.getByRole('button', { name: /sign in|log in/i }).click();
    await expect(page).toHaveURL(/\/$/);
  });

  test.afterEach(async ({ request }) => {
    if (setup) await request.post('/test/e2e/cleanup', { data: { run_id: setup.run_id } });
  });

  async function openConversation(page, request) {
    const response = await request.post('/test/e2e/conversation_fixture', {
      data: { account_id: setup.account_id, count: 65, prefix: 'Mobile history' },
    });
    expect(response.ok()).toBe(true);
    const fixture = await response.json();
    await page.goto(`/accounts/${setup.account_id}/chats/${fixture.chat_id}`);
    await expect(page.getByTestId('message-composer')).toBeVisible();
    return fixture;
  }

  test('composer stays at the viewport bottom after history scroll and viewport changes', async ({
    page,
    request,
  }, testInfo) => {
    await openConversation(page, request);
    const messages = page.getByTestId('chat-messages');
    await messages.evaluate((element) => {
      element.scrollTop = 40;
    });

    // Covers changing browser chrome/available height without pretending that
    // desktop Chromium emulation is a physical Android keyboard test.
    for (const height of [740, 620, 400, 740]) {
      await page.setViewportSize({ width: 360, height });
      await expect
        .poll(async () => {
          const box = await page.getByTestId('message-composer').boundingBox();
          return Math.abs(box.y + box.height - height);
        })
        .toBeLessThanOrEqual(2);
      expect(await page.evaluate(() => document.documentElement.scrollHeight)).toBeLessThanOrEqual(height + 1);
    }
    await page.screenshot({ path: testInfo.outputPath('mobile-history.png') });
  });

  for (const kind of ['existing', 'new']) {
    test(`${kind} chat keeps typing space when files are attached first`, async ({ page, request }, testInfo) => {
      if (kind === 'existing') await openConversation(page, request);
      else await page.goto(`/accounts/${setup.account_id}/chats`);
      const composer = page.getByTestId('message-composer');
      const input = composer.locator('textarea');
      await expect(input).toBeVisible();
      const before = await input.boundingBox();
      const filename = `Screenshot_20260924-205432_${'long-name-'.repeat(12)}.png`;
      await composer.locator('input[type=file]').setInputFiles({
        name: filename,
        mimeType: 'image/png',
        buffer: Buffer.from('synthetic attachment; not submitted'),
      });
      await expect(composer.getByText(filename, { exact: true })).toBeVisible();
      const after = await input.boundingBox();
      expect(after.width).toBeGreaterThan(160);
      expect(Math.abs(after.width - before.width)).toBeLessThanOrEqual(1);
      const attachment = await composer.getByText(filename, { exact: true }).boundingBox();
      expect(attachment.y).toBeGreaterThanOrEqual(after.y + after.height);
      await input.fill('The screenshot should not squeeze this message.');
      await expect(input).toHaveValue('The screenshot should not squeeze this message.');
      expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(360);
      await page.screenshot({ path: testInfo.outputPath(`mobile-${kind}-attachment.png`) });
      await composer.getByRole('button', { name: `Remove ${filename}`, exact: true }).click();
      await expect(composer.getByText(filename, { exact: true })).toBeHidden();
      await expect(input).toHaveValue('The screenshot should not squeeze this message.');
    });
  }

  for (const kind of ['existing', 'new']) {
    test(`${kind} long draft stays above a visual-only keyboard`, async ({ page, request }, testInfo) => {
      // Desktop Chromium cannot open an Android IME. Model its visual viewport
      // independently of the layout viewport, which stays at 740px throughout.
      await page.addInitScript(() => {
        const viewport = Object.assign(new EventTarget(), { height: 740, offsetTop: 0, scale: 1 });
        Object.defineProperty(window, 'visualViewport', { value: viewport, configurable: true });
      });
      if (kind === 'existing') await openConversation(page, request);
      else await page.goto(`/accounts/${setup.account_id}/chats`);
      const composer = page.getByTestId('message-composer');
      const input = composer.locator('textarea');
      const draft = Array.from({ length: 30 }, (_, i) => `Long draft line ${i}`).join('\n');
      await input.fill(draft);
      for (const [height, offsetTop] of [
        [350, 0],
        [350, 45],
        [290, 0],
        [740, 0],
      ]) {
        await page.evaluate(
          ({ height, offsetTop }) => {
            Object.assign(window.visualViewport, { height, offsetTop });
            window.visualViewport.dispatchEvent(new Event('resize'));
            window.visualViewport.dispatchEvent(new Event('scroll'));
          },
          { height, offsetTop }
        );
        await expect
          .poll(async () => {
            const box = await composer.boundingBox();
            return Math.abs(box.y + box.height - height - offsetTop);
          })
          .toBeLessThanOrEqual(2);
        const box = await input.boundingBox();
        expect(box.y).toBeGreaterThanOrEqual(offsetTop);
        expect(box.y + box.height).toBeLessThanOrEqual(offsetTop + height);
        expect(box.height).toBeLessThanOrEqual(Math.min(240, height * 0.35) + 1);
        await input.press('Control+End');
        await input.press('End');
        await input.press('a');
        await input.press('Backspace');
        await expect(input).toHaveValue(draft);
        expect(await input.evaluate((node) => node.scrollTop)).toBeGreaterThan(0);
        if (height === 350 && offsetTop === 0) {
          await page.screenshot({ path: testInfo.outputPath(`${kind}-keyboard-long-draft.png`) });
        }
      }
    });
  }

  test('completed prose keeps bare shell paths literal and within the mobile bubble', async ({ page, request }) => {
    const fixture = await openConversation(page, request);
    const content =
      'Stored in $MIRA_ROOT/secrets/example.json for my own machines. Keep these words spaced.\n\nRun from $MIRA_ROOT:\npython3 example.py\n\nSee https://example.org/' +
      'long-path-'.repeat(25);
    await request.post('/test/e2e/assistant_message', { data: { chat_id: fixture.chat_id, content } });
    await page.reload();
    const prose = page.locator('.prose').filter({ hasText: 'Stored in $MIRA_ROOT' });
    await expect(prose).toContainText('Keep these words spaced.');
    await expect(prose.locator('.katex')).toHaveCount(0);
    const box = await prose.boundingBox();
    expect(box.x).toBeGreaterThanOrEqual(0);
    expect(box.x + box.width).toBeLessThanOrEqual(360);
    const dimensions = await prose.evaluate((node) => ({ width: node.clientWidth, scrollWidth: node.scrollWidth }));
    expect(dimensions.scrollWidth).toBeLessThanOrEqual(dimensions.width + 1);
  });

  test('inline code uses contrasting theme colours in both themes alongside fenced code', async ({
    page,
    request,
  }, testInfo) => {
    const fixture = await openConversation(page, request);
    await request.post('/test/e2e/assistant_message', {
      data: { chat_id: fixture.chat_id, content: 'Check `VERSION` and `production`.\n\n```ruby\nputs "hello"\n```' },
    });
    await page.reload();
    const inline = page.locator('[data-streamdown-codespan]').filter({ hasText: 'VERSION' });
    await expect(inline).toBeVisible();
    await expect(page.locator('pre')).toBeVisible();
    for (const theme of ['dark', 'light']) {
      await page.emulateMedia({ colorScheme: theme });
      await expect
        .poll(() => page.locator('html').evaluate((node) => node.classList.contains('dark')))
        .toBe(theme === 'dark');
      const colors = await inline.evaluate((node) => {
        const styles = getComputedStyle(node);
        // Resolve theme tokens through the browser, not a hard-coded palette.
        const sample = document.createElement('span');
        sample.style.color = 'var(--foreground)';
        sample.style.backgroundColor = 'var(--muted)';
        document.body.append(sample);
        const expected = getComputedStyle(sample);
        const result = {
          foreground: styles.color,
          background: styles.backgroundColor,
          expectedForeground: expected.color,
          expectedBackground: expected.backgroundColor,
        };
        sample.remove();
        return result;
      });
      expect(colors.foreground).toBe(colors.expectedForeground);
      expect(colors.background).toBe(colors.expectedBackground);
      expect(colors.foreground).not.toBe(colors.background);
      await page.screenshot({ path: testInfo.outputPath(`inline-code-${theme}.png`) });
    }
  });
});
