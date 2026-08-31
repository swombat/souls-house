import { describe, expect, it } from 'vitest';
import {
  displayUsageWindows,
  predictedWeeklyUsage,
  predictionTone,
  resetDescription,
  usageLine,
} from './subscription-usage';

const now = Date.parse('2026-08-31T00:00:00Z');

describe('subscription usage display', () => {
  it('shows only the selected Gemini quota family', () => {
    const windows = displayUsageWindows(
      {
        windows: [
          { label: 'Gemini 5-hour', remaining_percent: 100, resets_at: '2026-08-31T04:33:00Z' },
          { label: 'Gemini weekly', remaining_percent: 95.3, resets_at: '2026-09-05T19:44:00Z' },
          { label: 'Claude/GPT weekly', remaining_percent: 50, resets_at: '2026-09-05T19:44:00Z' },
        ],
      },
      'gemini'
    );

    expect(windows.map((window) => window.displayLabel)).toEqual(['5-hour', 'Weekly']);
    expect(usageLine(windows[0], now, 'en-GB')).toBe('5-hour: 100% left, resets in 4h33m');
    expect(usageLine(windows[1], now, 'en-GB')).toBe('Weekly: 95.3% left, resets 5 Sept, 21:44');
  });

  it('treats the Grok subscription window as weekly', () => {
    const windows = displayUsageWindows(
      {
        windows: [{ label: 'Subscription', remaining_percent: 99, resets_at: '2026-09-06T22:32:00Z' }],
      },
      'xai'
    );

    expect(usageLine(windows[0], now, 'en-GB')).toBe('Weekly: 99% left, resets 7 Sept, 0:32');
  });

  it('hides Codex Spark limits unless that model is selected', () => {
    const usage = {
      windows: [
        { id: 'session', label: 'Session', remaining_percent: 100, resets_at: '2026-09-07T04:35:00Z' },
        {
          id: 'gpt-5-3-codex-spark-session',
          label: 'GPT-5.3-Codex-Spark session',
          remaining_percent: 20,
          resets_at: '2026-08-31T04:00:00Z',
        },
        {
          id: 'gpt-5-3-codex-spark-weekly',
          label: 'GPT-5.3-Codex-Spark weekly',
          remaining_percent: 30,
          resets_at: '2026-09-07T00:00:00Z',
        },
      ],
    };

    expect(displayUsageWindows(usage, 'openai', 'openai/gpt-5.6-sol')).toHaveLength(1);
    expect(displayUsageWindows(usage, 'openai', 'openai/gpt-5.3-codex-spark')).toHaveLength(2);
  });

  it('projects weekly usage from the elapsed fraction of a seven-day window', () => {
    const windows = [
      {
        displayLabel: 'Weekly',
        remaining_percent: 60,
        resets_at: new Date(now + 3.5 * 24 * 60 * 60 * 1000).toISOString(),
      },
    ];

    expect(predictedWeeklyUsage(windows, now)).toBe(80);
    expect(predictionTone(74)).toBe('muted');
    expect(predictionTone(75)).toBe('warning');
    expect(predictionTone(101)).toBe('danger');
  });

  it('formats short reset intervals compactly', () => {
    expect(resetDescription('2026-08-31T00:17:00Z', now, 'en-GB')).toBe('resets in 17m');
  });
});
