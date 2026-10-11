// The amber mark on a Field recording with speakers still to name (Mira's review of #305).
import { test, expect } from '@playwright/experimental-ct-svelte';
import FieldItemRow from '../../app/frontend/lib/components/field/FieldItemRow.svelte';
import FieldItemCard from '../../app/frontend/lib/components/field/FieldItemCard.svelte';

const base = {
  key: 'recording-review',
  kind: 'recording',
  status: 'ready',
  title: 'A long conversation title that still needs room beside its speakers',
  created_at: '2026-10-11T10:00:00Z',
  unnamed_speakers: 2,
  summary_short: 'An orchard conversation',
  duration_ms: 60000,
};

for (const [name, Component] of [
  ['row', FieldItemRow],
  ['card', FieldItemCard],
]) {
  for (const width of [375, 1280]) {
    for (const theme of ['light', 'dark']) {
      test(`${name} ${width} ${theme}: label and layout`, async ({ mount, page }) => {
        await page.setViewportSize({ width, height: 600 });
        await page.evaluate((theme) => document.documentElement.classList.toggle('dark', theme === 'dark'), theme);
        const component = await mount(Component, { props: { item: base, onSelect: () => {} } });
        const badge = page.getByTestId('field-unnamed-speakers');
        await expect(badge).toBeVisible();
        await expect(badge).toHaveAttribute('aria-label', '2 speakers to name');
        await expect(badge).toHaveAttribute('title', '2 speakers to name');
        const rect = await badge.boundingBox();
        expect(rect.x).toBeGreaterThanOrEqual(0);
        expect(rect.x + rect.width).toBeLessThanOrEqual(width);
        const item = await component.boundingBox();
        expect(item.x + item.width).toBeLessThanOrEqual(width);
        expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(width);
      });
    }
  }
  test(`${name}: resolved and pending states have no badge`, async ({ mount, page }) => {
    let component = await mount(Component, { props: { item: { ...base, unnamed_speakers: 0 }, onSelect: () => {} } });
    await expect(page.getByTestId('field-unnamed-speakers')).toHaveCount(0);
    await component.unmount();
    component = await mount(Component, { props: { item: { ...base, status: 'transcribing' }, onSelect: () => {} } });
    await expect(page.getByTestId('field-unnamed-speakers')).toHaveCount(0);
  });
}
