import { describe, expect, it, vi } from 'vitest';
import { showFlashToasts } from './flash-toasts.js';

const notifier = () => ({ success: vi.fn(), error: vi.fn() });

describe('showFlashToasts', () => {
  it('toasts a notice and an alert', () => {
    const notify = notifier();
    showFlashToasts({ notice: 'Saved', alert: 'But also' }, notify);
    expect(notify.success).toHaveBeenCalledWith('Saved');
    expect(notify.error).toHaveBeenCalledWith('But also');
  });

  it('does not toast the same flash object twice (partial reloads carry it over)', () => {
    const notify = notifier();
    const flash = { notice: 'Settings updated' };
    showFlashToasts(flash, notify);
    showFlashToasts(flash, notify);
    showFlashToasts(flash, notify);
    expect(notify.success).toHaveBeenCalledTimes(1);
  });

  it('toasts the same message again when a new visit brings a new flash', () => {
    const notify = notifier();
    showFlashToasts({ notice: 'Settings updated' }, notify);
    showFlashToasts({ notice: 'Settings updated' }, notify);
    expect(notify.success).toHaveBeenCalledTimes(2);
  });

  it('ignores missing or empty flash', () => {
    const notify = notifier();
    showFlashToasts(undefined, notify);
    showFlashToasts({}, notify);
    expect(notify.success).not.toHaveBeenCalled();
    expect(notify.error).not.toHaveBeenCalled();
  });
});
