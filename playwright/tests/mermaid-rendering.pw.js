import { test, expect } from '@playwright/experimental-ct-svelte';
import MessageBubble from '../../app/frontend/lib/components/chat/MessageBubble.svelte';
import WhiteboardViewer from '../../app/frontend/lib/components/whiteboards/WhiteboardViewer.svelte';

const content = '```mermaid\nflowchart LR\n  A[Start] --> B[Finished]\n```';

for (const role of ['user', 'assistant']) {
  test(`${role} messages render Mermaid diagrams`, async ({ mount }) => {
    const component = await mount(MessageBubble, {
      props: {
        message: { role, content, streaming: false, created_at: '2026-10-31T12:00:00Z' },
      },
    });
    const diagram = component.locator('[data-mermaid-svg]');
    await expect(diagram).toBeVisible();
    await expect(diagram).toContainText('Start');
    await expect(diagram).toContainText('Finished');
  });
}

test('whiteboards render Mermaid diagrams', async ({ mount }) => {
  const component = await mount(WhiteboardViewer, {
    props: { selected: { name: 'Diagram', content } },
  });
  await expect(component.locator('[data-mermaid-svg]')).toContainText('Finished');
});

test('radar ticks are capped without exercising an unbounded payload', async ({ mount }) => {
  // The advisory uses a billion ticks. 33 proves the same 32-tick cap without
  // risking memory exhaustion if an old dependency accidentally returns.
  const component = await mount(MessageBubble, {
    props: {
      message: {
        role: 'assistant',
        content: '```mermaid\nradar-beta\n  axis a, b\n  curve c {1, 1}\n  ticks 33\n```',
        streaming: false,
        created_at: '2026-10-31T12:00:00Z',
      },
    },
  });
  await expect(component.locator('[data-mermaid-svg] .radarGraticule')).toHaveCount(32);
});
