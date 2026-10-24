import { expect, test, vi } from 'vitest';
import { router } from '@inertiajs/svelte';
import { subscribeToModel } from './cable';

const { create } = vi.hoisted(() => ({ create: vi.fn(() => ({ unsubscribe: vi.fn() })) }));
vi.mock('@rails/actioncable', () => ({ createConsumer: () => ({ subscriptions: { create } }) }));

test('Telegram connect reconnect and marker bursts catch up exactly two safe props, never the registration link', () => {
  vi.useFakeTimers();
  const props = ['telegram_configuration', 'telegram_subscriber_count'];
  const unsubscribe = subscribeToModel('TelegramPresentation', 'resident', props);
  const [identity, callbacks] = create.mock.calls.at(-1);
  expect(identity).toEqual({ channel: 'SyncChannel', model: 'TelegramPresentation', id: 'resident' });
  for (const notify of [
    () => callbacks.connected(),
    () => callbacks.connected(),
    () => {
      callbacks.received({ action: 'refresh' });
      callbacks.received({ action: 'refresh' });
      callbacks.received({ action: 'refresh' });
    },
  ]) {
    router.reload.mockClear();
    notify();
    vi.advanceTimersByTime(300);
    expect(router.reload).toHaveBeenCalledOnce();
    expect(router.reload).toHaveBeenCalledWith(
      expect.objectContaining({ only: props, preserveState: true, preserveScroll: true, preserveUrl: true })
    );
    expect(router.reload.mock.calls[0][0].only).not.toContain('telegram_deep_link');
  }
  unsubscribe();
  expect(create.mock.results.at(-1).value.unsubscribe).toHaveBeenCalledOnce();
  vi.useRealTimers();
});
