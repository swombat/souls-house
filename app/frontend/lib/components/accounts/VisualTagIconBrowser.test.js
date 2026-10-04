import { fireEvent, render, screen } from '@testing-library/svelte';
import { expect, test } from 'vitest';
import VisualTagIconBrowser from './VisualTagIconBrowser.svelte';
import { visualTagIconNames } from '$lib/visual-tags';

test('searches the visual grid and selects an icon by pressing its picture', async () => {
  render(VisualTagIconBrowser, { options: ['ChatCircle', 'AirplaneTilt', 'Acorn'] });
  expect(screen.getByRole('button', { name: 'Acorn' }).querySelector('svg')).not.toBeNull();
  await fireEvent.input(screen.getByRole('searchbox'), { target: { value: 'airplane tilt' } });
  expect(screen.queryByRole('button', { name: 'Acorn' })).not.toBeInTheDocument();
  const choice = screen.getByRole('button', { name: 'Airplane Tilt' });
  await fireEvent.click(choice);
  expect(choice).toHaveAttribute('aria-pressed', 'true');
  await fireEvent.input(screen.getByRole('searchbox'), { target: { value: 'not an icon' } });
  expect(screen.getByText(/No icons match/)).toBeVisible();
});

test('the complete library remains browsable in batches without 1,500 tab stops', async () => {
  render(VisualTagIconBrowser, { options: visualTagIconNames });
  expect(screen.getAllByRole('button', { pressed: false })).toHaveLength(120);
  expect(document.querySelectorAll('button[tabindex="0"]')).toHaveLength(1);
  const first = screen.getByRole('button', { name: 'Acorn', exact: true });
  first.focus();
  await fireEvent.keyDown(first, { key: 'ArrowRight' });
  expect(document.activeElement).not.toBe(first);
  await fireEvent.click(screen.getByRole('button', { name: 'Show more icons' }));
  expect(screen.getAllByRole('button', { pressed: false })).toHaveLength(240);
  await fireEvent.input(screen.getByRole('searchbox'), { target: { value: 'money' } });
  expect(screen.getByRole('button', { name: 'Coins', exact: true })).toBeVisible();
});
