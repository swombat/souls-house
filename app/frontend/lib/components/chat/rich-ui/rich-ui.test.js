import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen } from '@testing-library/svelte';
import RichUi from './rich-ui.svelte';

afterEach(cleanup);
const text = (text = 'Hello') => ({
  version: 1,
  root: 'root',
  elements: { root: { type: 'Text', props: { text } } },
});

describe('custom static Renderer', () => {
  it('renders Card/Stack children, Text and Metric with escaped text, not HTML', () => {
    const value = {
      version: 1,
      root: 'stack',
      elements: {
        stack: { type: 'Stack', props: {}, children: ['card'] },
        card: { type: 'Card', props: { title: 'Summary' }, children: ['text', 'metric'] },
        text: { type: 'Text', props: { text: '<script>window.bad = true</script>' } },
        metric: { type: 'Metric', props: { label: 'Count', value: '12', detail: 'Today' } },
      },
    };
    const { container } = render(RichUi, { value });
    expect(screen.getByRole('heading', { name: 'Summary' })).toBeTruthy();
    expect(screen.getByText('12')).toBeTruthy();
    expect(screen.getByText('<script>window.bad = true</script>')).toBeTruthy();
    expect(container.querySelector('script')).toBeNull();
    expect(screen.getByText('View rich UI JSON')).toBeTruthy();
  });

  it('rejects dynamic props and actions before any component or code executes', () => {
    const callback = vi.fn();
    const unsafe = text();
    unsafe.elements.root.on = { press: { action: 'setState', params: { statePath: '/x', value: true } } };
    render(RichUi, { value: unsafe });
    expect(screen.getByRole('status').textContent).toContain('unsupported or invalid');
    expect(screen.queryByText('Hello')).toBeNull();
    cleanup();
    render(RichUi, { value: text({ $computed: callback }) });
    expect(callback).not.toHaveBeenCalled();
    expect(screen.getByRole('status')).toBeTruthy();
  });

  it('falls back for future or excessively deep specs and renders nothing for null', async () => {
    const { rerender, container } = render(RichUi, { value: null });
    expect(container.textContent).toBe('');
    await rerender({ value: { ...text(), version: 2 } });
    expect(screen.getByRole('status').textContent).toContain('message text is still available');
    const value = { version: 1, root: 'n0', elements: {} };
    for (let i = 0; i < 11; i++)
      value.elements[`n${i}`] = {
        type: 'Stack',
        props: {},
        children: i < 10 ? [`n${i + 1}`] : [],
      };
    await rerender({ value });
    expect(screen.getByRole('status')).toBeTruthy();
  });

  it('filters and sorts table cells with keyboard-native controls', async () => {
    render(RichUi, {
      value: {
        version: 1,
        root: 'table',
        elements: {
          table: {
            type: 'Table',
            props: {
              title: 'Values',
              columns: ['Value', 'Label'],
              rows: [
                [10, 'Ten'],
                [2, 'Two'],
                [null, 'None'],
                ['12', 'String'],
              ],
            },
          },
        },
      },
    });
    const values = () =>
      Array.from(screen.getByRole('table').querySelectorAll('tbody tr')).map((row) => row.cells[0].textContent);
    await fireEvent.click(screen.getByRole('button', { name: 'Value' }));
    expect(values()).toEqual(['2', '10', '12', '—']);
    await fireEvent.click(screen.getByRole('button', { name: /Value/ }));
    expect(values()).toEqual(['10', '2', '12', '—']);
    await fireEvent.input(screen.getByRole('searchbox'), { target: { value: 'Two' } });
    expect(values()).toEqual(['2']);
  });

  it.each(['line', 'bar'])('renders an accessible %s SVG and equivalent table', (kind) => {
    const { container } = render(RichUi, {
      value: {
        version: 1,
        root: 'chart',
        elements: {
          chart: {
            type: 'Chart',
            props: {
              title: 'Trend',
              kind,
              labels: ['Start', 'End'],
              series: [
                { name: 'Count', values: [-2, 3] },
                { name: 'Other', values: [0, 1] },
              ],
            },
          },
        },
      },
    });
    expect(screen.getByRole('img', { name: /Trend/ })).toBeTruthy();
    expect(screen.getByRole('list', { name: 'Chart legend' })).toBeTruthy();
    expect(screen.getByText('View chart data table')).toBeTruthy();
    expect(container.querySelector('table caption').textContent).toBe('Trend data');
    expect(container.querySelector('svg').innerHTML).not.toMatch(/NaN|Infinity/);
  });

  it('revokes local JSON Blob URLs when changed and unmounted', async () => {
    const create = vi.fn().mockReturnValueOnce('blob:first').mockReturnValueOnce('blob:second');
    const revoke = vi.fn();
    vi.stubGlobal('URL', Object.assign(class extends URL {}, { createObjectURL: create, revokeObjectURL: revoke }));
    try {
      const { rerender, unmount } = render(RichUi, { value: text() });
      expect(screen.getByRole('link', { name: 'Download JSON' }).getAttribute('href')).toBe('blob:first');
      await rerender({ value: text('Next') });
      expect(revoke).toHaveBeenCalledWith('blob:first');
      unmount();
      expect(revoke).toHaveBeenCalledWith('blob:second');
      expect(create.mock.calls[0][0]).toBeInstanceOf(Blob);
    } finally {
      vi.unstubAllGlobals();
    }
  });
});
