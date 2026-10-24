import { fireEvent, render, screen } from '@testing-library/svelte';
import { tick } from 'svelte';
import { expect, test, vi } from 'vitest';
import { router } from '@inertiajs/svelte';
import Glossary from './transcription_glossary.svelte';

const { update } = vi.hoisted(() => ({ update: vi.fn() }));
vi.mock('$lib/use-sync', () => ({ createDynamicSync: () => update }));

const home = { id: 'home', name: 'Home' };
const props = { account: home, path: '/accounts/home/glossary' };
const input = () => screen.getByRole('textbox', { name: 'Word or phrase' });
const edit = (value) => fireEvent.input(input(), { target: { value } });
const submit = () => fireEvent.submit(input().closest('form'));
const callbacks = () => router.post.mock.calls.at(-1)[2];
const accepted = (id = 'home') => ({
  component: 'accounts/transcription_glossary',
  props: { account: { id }, flash: { notice: 'Added "Draft"' } },
});

test('uses stable account-only term lanes and retains dirty input across partial props', async () => {
  const { rerender } = render(Glossary, props);
  const expected = { 'GlossaryActivity:home': ['terms', 'removed'], 'HomeResidentRoster:home': ['terms'] };
  expect(update).toHaveBeenLastCalledWith(expected);
  await edit('Unsent word');
  await rerender({ ...props, terms: [{ term: 'Remote', source: 'manual' }], removed: [] });
  expect(input()).toHaveValue('Unsent word');
  expect(update).toHaveBeenLastCalledWith(expected);
  await rerender({ account: { id: 'other', name: 'Other' }, path: '/accounts/other/glossary' });
  expect(input()).toHaveValue('');
  expect(update).toHaveBeenLastCalledWith({
    'GlossaryActivity:other': ['terms', 'removed'],
    'HomeResidentRoster:other': ['terms'],
  });
});

test('an acknowledged addition clears only its submitted generation, even after typing away and back', async () => {
  render(Glossary, props);
  await edit('Draft');
  await submit();
  const first = callbacks();
  await edit('Newer');
  await edit('Draft');
  first.onSuccess(accepted());
  first.onFinish();
  await tick();
  expect(input()).toHaveValue('Draft');
  await submit();
  callbacks().onSuccess(accepted());
  callbacks().onFinish();
  await tick();
  expect(input()).toHaveValue('');
});

test('refresh while in flight retains input and pending state; refusal cannot clear it', async () => {
  const { rerender } = render(Glossary, props);
  await edit('Draft');
  await submit();
  const pending = callbacks();
  await rerender({ ...props, terms: [{ term: 'Remote', source: 'manual' }] });
  expect(input()).toHaveValue('Draft');
  expect(screen.getByRole('button', { name: 'Add', exact: true })).toBeDisabled();
  pending.onSuccess({
    component: 'accounts/transcription_glossary',
    props: { account: home, flash: { alert: 'Refused' } },
  });
  pending.onFinish();
  await tick();
  expect(input()).toHaveValue('Draft');
  await submit();
  callbacks().onSuccess({ component: 'accounts/show', props: { account: home, flash: { notice: 'Added "Draft"' } } });
  callbacks().onFinish();
  await tick();
  expect(input()).toHaveValue('Draft');
});

test('account switch resets pending state and late callbacks cannot clear or finish a new request', async () => {
  const { rerender } = render(Glossary, props);
  await edit('Draft');
  await submit();
  const old = callbacks();
  await rerender({ account: { id: 'other', name: 'Other' }, path: '/accounts/other/glossary' });
  expect(input()).toHaveValue('');
  await edit('Other draft');
  await submit();
  old.onSuccess(accepted());
  old.onFinish();
  await tick();
  expect(input()).toHaveValue('Other draft');
  expect(screen.getByRole('button', { name: 'Add', exact: true })).toBeDisabled();
  callbacks().onFinish();
});

test('restoring a term never clears the unrelated input', async () => {
  render(Glossary, { ...props, removed: [{ term: 'Draft' }] });
  await edit('Draft');
  await fireEvent.click(screen.getByRole('button', { name: 'Restore' }));
  callbacks().onSuccess(accepted());
  callbacks().onFinish();
  await tick();
  expect(input()).toHaveValue('Draft');
});
