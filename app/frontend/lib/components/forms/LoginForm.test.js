import { render, screen } from '@testing-library/svelte';
import { page } from '@inertiajs/svelte';
import LoginForm from './LoginForm.svelte';

vi.mock('@inertiajs/svelte', async (importOriginal) => {
  const original = await importOriginal();
  const { writable } = await import('svelte/store');
  return { ...original, page: writable({ props: {} }) };
});

afterEach(() => page.set({ props: {} }));

test('closed admission hides signup but keeps login and password recovery', () => {
  page.set({ props: { site_settings: { allow_signups: false } } });
  render(LoginForm);
  expect(screen.queryByRole('link', { name: 'Sign up' })).not.toBeInTheDocument();
  expect(screen.getByText('New signups are currently closed.')).toBeVisible();
  expect(screen.getByRole('link', { name: 'Forgot your password?' })).toBeVisible();
  expect(screen.getByRole('button', { name: 'Log in' })).toBeEnabled();
});

test('open admission keeps signup available', () => {
  page.set({ props: { site_settings: { allow_signups: true } } });
  render(LoginForm);
  expect(screen.getByRole('link', { name: 'Sign up' })).toBeVisible();
});
