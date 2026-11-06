import { describe, expect, test, vi } from 'vitest';
import { downloadAll } from './download-all.js';

describe('downloadAll', () => {
  test('clicks one hidden link per file, spaced out, in order', () => {
    const delays = [];
    const clicked = [];
    const schedule = (fn, delay) => {
      delays.push(delay);
      fn();
    };
    const click = vi.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(function () {
      clicked.push([this.getAttribute('href'), this.download]);
    });

    const count = downloadAll(
      [
        { url: '/rails/a', filename: 'a.mp4' },
        { url: null, filename: 'broken' },
        { url: '/rails/b', filename: 'b.mp4' },
      ],
      { schedule, gapMs: 400 }
    );

    expect(count).toBe(2);
    expect(delays).toEqual([0, 400]);
    expect(clicked).toEqual([
      ['/rails/a', 'a.mp4'],
      ['/rails/b', 'b.mp4'],
    ]);
    expect(document.querySelectorAll('a').length).toBe(0);
    click.mockRestore();
  });
});
