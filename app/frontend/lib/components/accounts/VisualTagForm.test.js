import { fireEvent, render, screen } from '@testing-library/svelte';
import { router } from '@inertiajs/svelte';
import { expect, test, vi } from 'vitest';
import VisualTagForm from './VisualTagForm.svelte';

const tag = { id: 'tag-one', label: 'Building', icon: 'Wrench', colour: 'blue' };
const props = {
  accountId: 'house',
  tag,
  canManage: true,
  iconOptions: ['ChatCircle', 'Wrench', 'Heart'],
  colourOptions: ['slate', 'blue', 'rose'],
};

test('edits all three fields using a scoped stable ID', async () => {
  render(VisualTagForm, props);
  expect(screen.getByRole('button', { name: 'Save changes' })).toBeDisabled();
  await fireEvent.input(screen.getByLabelText('Label'), { target: { value: 'Care' } });
  await fireEvent.click(screen.getByRole('button', { name: 'Heart', exact: true }));
  await fireEvent.click(screen.getByRole('button', { name: 'Colour: rose' }));
  await fireEvent.submit(screen.getByRole('form'));
  expect(router.patch).toHaveBeenCalledWith(
    '/accounts/house/visual_tags/tag-one',
    { visual_tag: { label: 'Care', icon: 'Heart', colour: 'rose' } },
    expect.objectContaining({ preserveScroll: true })
  );
});

test('adds a tag and keeps failed input with validation errors visible', async () => {
  render(VisualTagForm, { ...props, tag: null });
  await fireEvent.input(screen.getByLabelText('Label'), { target: { value: ' New label ' } });
  await fireEvent.submit(screen.getByRole('form'));
  expect(router.post).toHaveBeenCalledWith(
    '/accounts/house/visual_tags',
    { visual_tag: { label: 'New label', icon: 'ChatCircle', colour: 'slate' } },
    expect.any(Object)
  );
  const options = router.post.mock.calls.at(-1)[2];
  options.onError({ label: ['has already been taken'] });
  options.onFinish();
  expect(await screen.findByRole('alert')).toHaveTextContent('has already been taken');
  expect(screen.getByLabelText('Label')).toHaveValue(' New label ');
});

test('read-only members cannot mutate the palette', () => {
  render(VisualTagForm, { ...props, canManage: false });
  expect(screen.getByLabelText('Label')).toBeDisabled();
  expect(screen.getByRole('button', { name: 'Heart', exact: true })).toBeDisabled();
  expect(screen.getByRole('button', { name: 'Colour: rose' })).toBeDisabled();
  expect(screen.queryByRole('button', { name: 'Save changes' })).not.toBeInTheDocument();
});

test('deleting explains the effect on tagged conversations and allows cancellation', async () => {
  const confirm = vi.spyOn(window, 'confirm').mockReturnValue(false);
  render(VisualTagForm, props);
  await fireEvent.click(screen.getByRole('button', { name: 'Remove tag' }));
  expect(confirm).toHaveBeenCalledWith(expect.stringContaining('Conversations using it will have no tag'));
  expect(router.delete).not.toHaveBeenCalled();
  confirm.mockReturnValue(true);
  await fireEvent.click(screen.getByRole('button', { name: 'Remove tag' }));
  expect(router.delete).toHaveBeenCalledWith('/accounts/house/visual_tags/tag-one', expect.any(Object));
  confirm.mockRestore();
});

test('live edits update untouched forms but do not overwrite an unsaved edit', async () => {
  const { rerender } = render(VisualTagForm, props);
  await rerender({ ...props, tag: { ...tag, label: 'Making' } });
  expect(screen.getByLabelText('Label')).toHaveValue('Making');
  await fireEvent.input(screen.getByLabelText('Label'), { target: { value: 'My edit' } });
  await rerender({ ...props, tag: { ...tag, label: 'Projects' } });
  expect(screen.getByLabelText('Label')).toHaveValue('My edit');
});
