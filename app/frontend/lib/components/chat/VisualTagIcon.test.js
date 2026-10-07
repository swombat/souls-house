import { render } from '@testing-library/svelte';
import { expect, test } from 'vitest';
import VisualTagIcon from './VisualTagIcon.svelte';

test('renders arbitrary catalog icons from the bundled sprite and preserves size and colour classes', async () => {
  const { container, rerender } = render(VisualTagIcon, {
    icon: 'Yarn',
    size: 24,
    weight: 'duotone',
    class: 'text-rose-600',
  });
  const svg = container.querySelector('svg');
  expect(svg).toHaveAttribute('width', '24');
  expect(svg).toHaveAttribute('height', '24');
  expect(svg).toHaveAttribute('viewBox', '0 0 256 256');
  expect(svg).toHaveAttribute('fill', 'currentColor');
  expect(svg).toHaveClass('text-rose-600');
  expect(svg).toHaveAttribute('aria-hidden', 'true');
  expect(container.querySelector('use').getAttribute('href')).toMatch(/visual-tag-icons\.svg#Yarn-duotone$/);

  await rerender({ icon: 'Acorn', size: 16, weight: 'regular' });
  expect(container.querySelector('use').getAttribute('href')).toMatch(/#Acorn-regular$/);
});

test('untrusted names and unsupported weights cannot choose markup, paths or URLs', () => {
  const { container } = render(VisualTagIcon, { icon: 'https://evil.invalid/a.svg#script', weight: '<script>' });
  expect(container.querySelector('use').getAttribute('href')).toMatch(/#ChatCircle-regular$/);
  expect(container.querySelector('script')).toBeNull();
  expect(container.querySelector('path')).toBeNull();
});

test('tag displays default to the duotone weight', () => {
  const { container } = render(VisualTagIcon, { icon: 'Coins' });
  expect(container.querySelector('use').getAttribute('href')).toMatch(/#Coins-duotone$/);
});
