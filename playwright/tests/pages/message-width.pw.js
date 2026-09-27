import { test, expect } from '@playwright/experimental-ct-svelte';
import MessageBubble from '../../../app/frontend/lib/components/chat/MessageBubble.svelte';

const content = [
  'A normal paragraph before the code should stay inside the message bubble.',
  '```ruby',
  "response if: -> res { res.successful? && res.request.params in controller: 'api/v1/conversations', action: 'show' } do |res|",
  '  data = JSON.parse(res.body, symbolize_names: true)',
  'end',
  '```',
  'A normal paragraph after the code should wrap to the available width.',
].join('\n');

for (const width of [320, 390, 768, 1280]) {
  for (const [role, editable] of [
    ['user', true],
    ['user', false],
    ['assistant', false],
  ]) {
    test(`${role} (editable: ${editable}) code stays inside a ${width}px viewport`, async ({ mount, page }) => {
      await page.setViewportSize({ width, height: 844 });
      const component = await mount(MessageBubble, {
        props: {
          message: {
            id: 'wide-code',
            role,
            content,
            created_at: '2026-09-27T11:37:09Z',
            editable,
            deletable: editable,
          },
        },
      });
      await expect(component.locator('pre')).toBeVisible();
      await expect(component.locator('pre code span[style*="color:"]').first()).toBeVisible();
      const sizes = await component.evaluate((element) => {
        const card = element.querySelector('.bg-card');
        const pre = element.querySelector('pre');
        const paragraphs = [...element.querySelectorAll('p')];
        return {
          rowDisplay: getComputedStyle(element.querySelector('.group')).display,
          columnMaxWidth: getComputedStyle(element.querySelector('.group > div')).maxWidth,
          columnLeft: element.querySelector('.group > div').getBoundingClientRect().left,
          viewport: document.documentElement.clientWidth,
          document: document.documentElement.scrollWidth,
          cardRight: card.getBoundingClientRect().right,
          cardLeft: card.getBoundingClientRect().left,
          paragraphRight: Math.max(...paragraphs.map((p) => p.getBoundingClientRect().right)),
          preClient: pre.clientWidth,
          preScroll: pre.scrollWidth,
        };
      });
      expect(sizes.rowDisplay).toBe('flex');
      expect(sizes.columnMaxWidth).toBe(width >= 768 ? '70%' : '85%');
      expect(sizes.document).toBeLessThanOrEqual(sizes.viewport);
      expect(sizes.cardRight).toBeLessThanOrEqual(sizes.viewport);
      expect(sizes.cardLeft).toBeGreaterThanOrEqual(0);
      expect(sizes.cardLeft).toBeGreaterThanOrEqual(sizes.columnLeft);
      expect(sizes.paragraphRight).toBeLessThanOrEqual(sizes.viewport);
      // Long source lines remain intact and scroll locally, rather than
      // forcing ordinary prose and the whole conversation off-screen.
      expect(sizes.preScroll).toBeGreaterThan(sizes.preClient);
    });
  }
}
