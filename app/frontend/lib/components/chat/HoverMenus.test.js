import { fireEvent, render, screen } from '@testing-library/svelte';
import { afterEach, beforeEach, expect, test, vi } from 'vitest';
import ChatRowActions from './ChatRowActions.svelte';
import VisualTagPicker from './VisualTagPicker.svelte';

// Desktop hover-to-open for the chat list's tag picker and ⋯ menu.
const chat = { id: 'chat-one', title: 'A question', visual_tag: null, room_id: null };
const tags = [{ id: 'tag-1', label: 'Quest', icon: 'star', colour: 'amber' }];

function pointer(matches) {
  window.matchMedia = vi.fn(() => ({ matches, addEventListener: vi.fn(), removeEventListener: vi.fn() }));
}

// jsdom has no PointerEvent, so fireEvent.pointerEnter would drop pointerType.
class TestPointerEvent extends MouseEvent {
  constructor(type, init = {}) {
    super(type, init);
    this.pointerType = init.pointerType || '';
  }
}
const realPointerEvent = window.PointerEvent;

beforeEach(() => {
  window.PointerEvent = TestPointerEvent;
  vi.useFakeTimers();
});
afterEach(() => {
  vi.useRealTimers();
  window.PointerEvent = realPointerEvent;
  delete window.matchMedia;
});

const enter = (el, pointerType = 'mouse') => fireEvent.pointerEnter(el, { pointerType });
const leave = (el, pointerType = 'mouse') => fireEvent.pointerLeave(el, { pointerType });

async function settle(ms) {
  await vi.advanceTimersByTimeAsync(ms);
}

for (const [name, Component, props, trigger, item] of [
  ['⋯ menu', ChatRowActions, { chat, accountId: 'house', rooms: [] }, /^Actions for /, 'Archive'],
  ['tag picker', VisualTagPicker, { chat, accountId: 'house', tags }, /^Change visual tag/, 'Quest'],
]) {
  test(`${name}: resting a mouse on the button opens it, leaving closes it`, async () => {
    pointer(true);
    render(Component, props);
    const button = screen.getByRole('button', { name: trigger });
    await enter(button);
    await settle(200);
    expect(screen.getByRole('menuitem', { name: item })).toBeInTheDocument();
    expect(button).toHaveAttribute('aria-expanded', 'true');

    await leave(button);
    await settle(400);
    expect(button).toHaveAttribute('aria-expanded', 'false');
  });

  test(`${name}: moving from the button into the menu keeps it open`, async () => {
    pointer(true);
    render(Component, props);
    const button = screen.getByRole('button', { name: trigger });
    await enter(button);
    await settle(200);
    await leave(button);
    await settle(100);
    await enter(screen.getByRole('menu'));
    await settle(400);
    expect(button).toHaveAttribute('aria-expanded', 'true');
  });

  test(`${name}: a mouse passing over without resting does not open it`, async () => {
    pointer(true);
    render(Component, props);
    const button = screen.getByRole('button', { name: trigger });
    await enter(button);
    await settle(50);
    await leave(button);
    await settle(400);
    expect(button).toHaveAttribute('aria-expanded', 'false');
  });

  test(`${name}: a click on a hover-opened menu pins it open`, async () => {
    pointer(true);
    render(Component, props);
    const button = screen.getByRole('button', { name: trigger });
    await enter(button);
    await settle(200);
    await fireEvent.pointerDown(button, { pointerType: 'mouse', button: 0 });
    await leave(button);
    await settle(400);
    expect(button).toHaveAttribute('aria-expanded', 'true');
  });

  test(`${name}: no hover-open on a phone (touch, or no hover-capable pointer)`, async () => {
    pointer(false);
    render(Component, props);
    const button = screen.getByRole('button', { name: trigger });
    await enter(button);
    await settle(400);
    expect(button).toHaveAttribute('aria-expanded', 'false');
    pointer(true);
    await enter(button, 'touch');
    await settle(400);
    expect(button).toHaveAttribute('aria-expanded', 'false');
  });
}
