import { test, expect } from '@playwright/experimental-ct-svelte';
import AgentIndexHeader from '../../app/frontend/lib/components/agents/AgentIndexHeader.svelte';

const props = (calls) => ({
  onCreate: () => calls.push('create'),
  githubImportUrl: '/github',
  archiveImportUrl: '/import',
});

test.describe('touch', () => {
  test.use({ hasTouch: true, isMobile: true, viewport: { width: 390, height: 844 } });

  test('first native tap reveals the choices without creating', async ({ mount, page }) => {
    const calls = [];
    const component = await mount(AgentIndexHeader, { props: props(calls) });
    await component.getByRole('button', { name: 'New Resident', exact: true }).tap();
    await expect(page.getByRole('link', { name: 'Import a resident archive' })).toBeVisible();
    await expect(page.getByRole('link', { name: 'Bring an existing GitHub resident' })).toBeVisible();
    expect(calls).toEqual([]);

    await page.getByRole('button', { name: 'Start a new resident' }).tap();
    await expect.poll(() => calls).toEqual(['create']);
  });

  test('second tap on the button creates', async ({ mount, page }) => {
    const calls = [];
    const component = await mount(AgentIndexHeader, { props: props(calls) });
    const button = component.getByRole('button', { name: 'New Resident', exact: true });
    await button.tap();
    expect(calls).toEqual([]);
    await button.tap();
    await expect.poll(() => calls).toEqual(['create']);
  });
});

test('mouse hover reveals the choices and a click still creates', async ({ mount, page }) => {
  const calls = [];
  const component = await mount(AgentIndexHeader, { props: props(calls) });
  const button = component.getByRole('button', { name: 'New Resident', exact: true });
  await button.hover();
  await expect(page.getByRole('link', { name: 'Import a resident archive' })).toBeVisible();
  await page.getByRole('link', { name: 'Import a resident archive' }).hover();
  await expect(page.getByRole('link', { name: 'Import a resident archive' })).toBeVisible();
  await button.click();
  await expect.poll(() => calls).toEqual(['create']);
});

test('keyboard focus opens the panel, Escape returns focus to the button closed', async ({ mount, page }) => {
  const calls = [];
  const component = await mount(AgentIndexHeader, { props: props(calls) });
  const button = component.getByRole('button', { name: 'New Resident', exact: true });
  await page.keyboard.press('Tab');
  await expect(button).toBeFocused();
  await expect(button).toHaveAttribute('aria-expanded', 'true');
  await page.keyboard.press('Tab');
  await expect(page.getByRole('button', { name: 'Start a new resident' })).toBeFocused();
  await page.keyboard.press('Tab');
  await expect(page.getByRole('link', { name: 'Bring an existing GitHub resident' })).toBeFocused();

  await page.keyboard.press('Escape');
  await expect(button).toBeFocused();
  await expect(button).toHaveAttribute('aria-expanded', 'false');
  await expect(page.getByRole('link', { name: 'Import a resident archive' })).toHaveCount(0);

  await page.keyboard.press('Enter');
  await expect.poll(() => calls).toEqual(['create']);
});
