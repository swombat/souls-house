import { render, screen, fireEvent, waitFor } from '@testing-library/svelte';
import { vi } from 'vitest';
import { router } from '@inertiajs/svelte';
import NewChat from './new.svelte';

const props = {
  account: { id: 'account' },
  agents: [{ id: 'resident', name: 'Resident', active: true }],
};

beforeEach(() => vi.clearAllMocks());
afterEach(() => vi.unstubAllGlobals());

test('records the first message using the account endpoint and submits its audio', async () => {
  const stop = vi.fn();
  vi.stubGlobal('navigator', {
    mediaDevices: { getUserMedia: vi.fn().mockResolvedValue({ getTracks: () => [{ stop }] }) },
  });
  vi.stubGlobal(
    'MediaRecorder',
    class {
      static isTypeSupported() {
        return true;
      }
      mimeType = 'audio/webm';
      start() {
        this.state = 'recording';
      }
      stop() {
        this.ondataavailable({ data: new Blob(['x'.repeat(2000)]) });
        this.onstop();
      }
    }
  );
  const fetch = vi.fn().mockResolvedValue({
    ok: true,
    json: async () => ({ text: 'Hello from my microphone', audio_signed_id: 'signed-audio' }),
  });
  vi.stubGlobal('fetch', fetch);
  render(NewChat, props);
  await fireEvent.click(screen.getByTitle('Record voice message'));
  await fireEvent.click(await screen.findByTitle('Stop recording'));
  await waitFor(() => expect(router.post).toHaveBeenCalled());
  expect(fetch.mock.calls[0][0]).toBe('/accounts/account/chats/transcription');
  const body = router.post.mock.calls[0][1];
  expect(body.get('message')).toBe('Hello from my microphone');
  expect(body.get('audio_signed_id')).toBe('signed-audio');
  expect(body.getAll('agent_ids[]')).toEqual(['resident']);
  expect(stop).toHaveBeenCalled();
});

test('shows recording errors without creating a conversation', async () => {
  vi.stubGlobal('navigator', {
    mediaDevices: { getUserMedia: vi.fn().mockRejectedValue({ name: 'NotAllowedError' }) },
  });
  render(NewChat, props);
  await fireEvent.click(screen.getByTitle('Record voice message'));
  expect(await screen.findByRole('alert')).toHaveTextContent('Microphone access denied');
  expect(router.post).not.toHaveBeenCalled();
});
