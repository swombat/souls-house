import { cleanup, fireEvent, render, screen } from '@testing-library/svelte';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { router } from '@inertiajs/svelte';
import ResidentApiKeys from './ResidentApiKeys.svelte';

const props = {
  residentName: 'Mira',
  create_url: '/residents/42/keys',
  keys: [{ id: 7, name: 'Desktop', created_at: 'Today', revoke_url: '/residents/42/keys/7' }],
};

beforeEach(() => vi.clearAllMocks());
afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});

describe('ResidentApiKeys', () => {
  it('explains identity, visible names, rotation and exposes the Settings anchor', () => {
    const { container } = render(ResidentApiKeys, props);
    expect(container.querySelector('#connect-another-body')).not.toBeNull();
    expect(screen.getByText(/This key lets that body read and post as Mira/)).toBeTruthy();
    expect(screen.getByTestId('resident-key-warning').textContent).toMatch(/Everyone in a conversation sees the name/);
    expect(screen.getByTestId('resident-key-warning').textContent).toMatch(/credentials revokes these keys too/);
  });

  it('creates a named body key at the supplied URL and prevents duplicate submits', async () => {
    render(ResidentApiKeys, { ...props, keys: [] });
    expect(screen.getByRole('button', { name: 'Create key' }).disabled).toBe(true);
    await fireEvent.input(screen.getByLabelText('Where this body lives'), { target: { value: ' Laptop ' } });
    await fireEvent.click(screen.getByRole('button', { name: 'Create key' }));
    expect(router.post).toHaveBeenCalledWith(props.create_url, { name: 'Laptop' }, expect.any(Object));
    expect(screen.getByRole('button', { name: 'Create key' }).disabled).toBe(true);
    expect(screen.getByText('No other bodies connected yet.')).toBeTruthy();
  });

  it('revokes only the selected key after confirmation', async () => {
    const confirm = vi.spyOn(window, 'confirm').mockReturnValue(false);
    render(ResidentApiKeys, props);
    await fireEvent.click(screen.getByRole('button', { name: 'Revoke Desktop' }));
    expect(router.delete).not.toHaveBeenCalled();
    confirm.mockReturnValue(true);
    await fireEvent.click(screen.getByRole('button', { name: 'Revoke Desktop' }));
    expect(router.delete).toHaveBeenCalledWith(props.keys[0].revoke_url, { preserveScroll: true });
  });
});
