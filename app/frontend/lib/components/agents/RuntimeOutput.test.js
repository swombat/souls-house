import { render, screen } from '@testing-library/svelte';
import RuntimeOutput from './RuntimeOutput.svelte';

test('shows stdout directly as text, not HTML, and keeps stderr collapsed', () => {
  const stdout = '<img src=x onerror=alert(1)>\nA resident response';
  const { container } = render(RuntimeOutput, { interaction: { stdout, stderr: 'A warning' } });
  const output = container.querySelector('pre');
  expect(output.textContent).toBe(stdout);
  expect(output.closest('details')).toBeNull();
  expect(container.querySelector('img')).toBeNull();
  expect(screen.getByText('A warning').closest('details')).not.toHaveAttribute('open');
});

test('makes missing output and captured tails explicit', () => {
  render(RuntimeOutput, {
    interaction: { stdout: null, stderr: 'last part', stderr_may_be_truncated: true },
  });
  expect(screen.getByText('No stdout was captured for this trigger.')).toBeInTheDocument();
  expect(screen.getByText(/tail only; earlier output may be missing/)).toBeInTheDocument();
});
