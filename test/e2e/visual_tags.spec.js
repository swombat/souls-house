import { expect, test } from '@playwright/test';

for (const mobile of [false, true]) {
  test.describe(`visual tags (${mobile ? 'touch' : 'desktop'})`, () => {
    if (mobile) test.use({ viewport: { width: 390, height: 844 }, hasTouch: true, isMobile: true });

    test('configure, select, rename, clear and delete without navigating the discussion list', async ({
      page,
      request,
    }, testInfo) => {
      const response = await request.post('/test/e2e/setup', {
        data: { run_id: `visual-tags-${mobile}-${Date.now()}` },
      });
      expect(response.ok()).toBe(true);
      const setup = await response.json();
      try {
        const fixture = await request.post('/test/e2e/conversation_fixture', {
          data: { account_id: setup.account_id, count: 1 },
        });
        expect(fixture.ok()).toBe(true);
        await page.goto('/login');
        await page.getByLabel(/email/i).fill(setup.primary_user.email);
        await page.getByLabel(/password/i).fill(setup.password);
        await page.getByRole('button', { name: /log in/i }).click();
        await expect(page).toHaveURL(/\/$/);
        const base = `/accounts/${setup.account_param}`;
        await page.goto(`${base}/interface`);
        await expect(page.getByRole('heading', { name: 'Visual tags', exact: true })).toBeVisible();
        await expect(page.getByRole('button', { name: /^Edit / })).toHaveCount(9);
        const defaults = [
          'Building',
          'Care',
          'Conversation',
          'Creative',
          'Help',
          'Plans',
          'Reading',
          'Reflection',
          'Research',
        ];
        const palette = page.getByLabel('Visual tag palette', { exact: true });
        await expect(palette.getByRole('button')).toHaveText(defaults.map((label) => `${label} (0)`));
        await page.screenshot({ path: testInfo.outputPath('interface.png'), fullPage: true });
        await page.getByRole('button', { name: 'Add tag', exact: true }).click();
        const form = page.getByRole('form', { name: 'Add visual tag', exact: true });
        await form.getByLabel('Label', { exact: true }).fill('Experiments');
        await form.getByRole('button', { name: 'Colour: cyan' }).click();
        await expect(form.getByRole('button', { name: 'Chat Circle', exact: true })).toBeVisible();
        // The symbols must actually render, not just leave an empty SVG-sized box.
        await expect
          .poll(() =>
            form
              .getByRole('button', { name: 'Chat Circle', exact: true })
              .locator('svg')
              .evaluate((svg) => svg.getBBox().width)
          )
          .toBeGreaterThan(0);
        await page.screenshot({ path: testInfo.outputPath('icon-browser.png') });
        await form.getByRole('searchbox', { name: 'Search icons' }).fill('money');
        await expect(form.getByRole('button', { name: 'Coins', exact: true })).toBeVisible();
        await form.getByRole('searchbox', { name: 'Search icons' }).fill('atom');
        await expect(form.getByRole('button', { name: 'Atom', exact: true }).locator('svg use')).toHaveAttribute(
          'href',
          /#Atom-duotone$/
        );
        await form.getByRole('button', { name: 'Atom', exact: true }).click();
        await form.getByRole('button', { name: 'Colour: cyan' }).click();
        await page.screenshot({ path: testInfo.outputPath('icon-search.png') });
        await form.getByRole('button', { name: 'Add tag', exact: true }).click();
        await expect(page.getByRole('dialog')).toHaveCount(0);
        await expect(page.getByRole('button', { name: 'Edit Experiments' })).toBeVisible();
        const experimentTile = page.getByRole('button', { name: 'Edit Experiments' });
        if (mobile) await experimentTile.tap();
        else await experimentTile.click();
        await expect(page.getByRole('button', { name: 'Colour: cyan' })).toHaveAttribute('aria-pressed', 'true');
        await page.getByRole('searchbox', { name: 'Search icons' }).fill('atom');
        await expect(page.getByRole('button', { name: 'Atom', exact: true })).toHaveAttribute('aria-pressed', 'true');
        await page.getByRole('button', { name: 'Cancel', exact: true }).click();
        expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);

        async function choose(label, choice) {
          const nav = mobile
            ? page.getByRole('navigation', { name: 'Recent conversations' })
            : page.locator('aside').first();
          const button = nav.getByRole('button', { name: `Change visual tag: ${label}`, exact: true }).first();
          // New props can arrive before the previous PATCH's onFinish enables
          // this control again; focus() alone does not wait for that boundary.
          await expect(button).toBeEnabled();
          if (mobile) await button.tap();
          else {
            await button.focus();
            await page.keyboard.press('Enter');
          }
          const option = page.getByRole('menuitem', { name: choice, exact: true });
          if (mobile) await option.tap();
          else await option.click();
          await expect(
            nav.getByRole('button', { name: `Change visual tag: ${choice}`, exact: true }).first()
          ).toBeVisible();
          await expect(page).toHaveURL(new RegExp(`${base}/chats/new$`));
        }

        await page.goto(`${base}/chats/new`);
        await choose('No tag', 'Experiments');
        await page.reload();
        await choose('Experiments', 'No tag');
        await choose('No tag', 'Experiments');
        await page.screenshot({ path: testInfo.outputPath('tagged-list.png') });
        const tagNav = mobile
          ? page.getByRole('navigation', { name: 'Recent conversations' })
          : page.locator('aside').first();
        await tagNav.getByRole('button', { name: 'Change visual tag: Experiments', exact: true }).first().click();
        await expect(page.getByRole('menuitem')).toHaveText(['No tag', 'Experiments', ...defaults]);
        await page.keyboard.press('Escape');
        await page.goto(`${base}/interface`);
        await expect(palette.getByRole('button')).toHaveText([
          'Experiments (1)',
          ...defaults.map((label) => `${label} (0)`),
        ]);
        await page.screenshot({ path: testInfo.outputPath('usage-ranked-palette.png'), fullPage: true });
        await page.getByRole('button', { name: 'Edit Experiments' }).click();
        const edit = page.getByRole('form', { name: 'Edit Experiments' });
        await edit.getByLabel('Label', { exact: true }).fill('Fieldwork');
        await edit.getByRole('button', { name: 'Save changes' }).click();
        await expect(page.getByRole('button', { name: 'Edit Fieldwork' })).toBeVisible();
        await page.goto(`${base}/chats/new`);
        const nav = mobile
          ? page.getByRole('navigation', { name: 'Recent conversations' })
          : page.locator('aside').first();
        await expect(nav.getByRole('button', { name: 'Change visual tag: Fieldwork' }).first()).toBeVisible();
        await page.goto(`${base}/interface`);
        await page.getByRole('button', { name: 'Edit Fieldwork' }).click();
        page.once('dialog', (dialog) => dialog.accept());
        await page
          .getByRole('form', { name: 'Edit Fieldwork' })
          .getByRole('button', { name: 'Remove tag', exact: true })
          .click();
        await expect(page.getByRole('form', { name: 'Edit Fieldwork' })).toHaveCount(0);
        await page.goto(`${base}/chats/new`);
        await expect(nav.getByRole('button', { name: 'Change visual tag: Fieldwork' })).toHaveCount(0);
        await expect(nav.getByRole('button', { name: 'Change visual tag: No tag' }).first()).toBeVisible();
      } finally {
        expect((await request.post('/test/e2e/cleanup', { data: { run_id: setup.run_id } })).ok()).toBe(true);
      }
    });
  });
}
