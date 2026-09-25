import { afterEach, expect, test, vi } from 'vitest';
import { chatViewport } from './chat-viewport';

afterEach(() => vi.unstubAllGlobals());

function fixture() {
  const viewport = Object.assign(new EventTarget(), { height: 740, offsetTop: 0, scale: 1 });
  vi.stubGlobal('visualViewport', viewport);
  const node = document.createElement('div');
  const action = chatViewport(node, true);
  return { viewport, node, action };
}

test('tracks visual-only keyboard resizing and panning, then restores on close', () => {
  const { viewport, node, action } = fixture();
  viewport.height = 350;
  viewport.dispatchEvent(new Event('resize'));
  expect(node.style.getPropertyValue('--chat-viewport-height')).toBe('350px');
  viewport.offsetTop = 45;
  viewport.dispatchEvent(new Event('scroll'));
  expect(node.style.getPropertyValue('--chat-viewport-top')).toBe('45px');
  viewport.height = 740;
  viewport.offsetTop = 0;
  viewport.dispatchEvent(new Event('resize'));
  expect(node.style.getPropertyValue('--chat-viewport-height')).toBe('740px');
  expect(node.style.getPropertyValue('--chat-viewport-top')).toBe('0px');
  action.destroy();
});

test('does not reflow the shell while pinch zooming', () => {
  const { viewport, node, action } = fixture();
  viewport.scale = 2;
  viewport.height = 370;
  viewport.dispatchEvent(new Event('resize'));
  expect(node.style.getPropertyValue('--chat-viewport-height')).toBe('740px');
  action.destroy();
});

test('clears on navigation away and stops listening after destroy', () => {
  const { viewport, node, action } = fixture();
  action.update(false);
  viewport.dispatchEvent(new Event('resize'));
  expect(node.style.cssText).toBe('');
  action.update(true);
  expect(node.style.getPropertyValue('--chat-viewport-height')).toBe('740px');
  action.destroy();
  viewport.dispatchEvent(new Event('resize'));
  window.dispatchEvent(new Event('resize'));
  expect(node.style.cssText).toBe('');
});

test('falls back to window height without the visual viewport API', () => {
  vi.stubGlobal('visualViewport', undefined);
  const node = document.createElement('div');
  const action = chatViewport(node, true);
  expect(node.style.getPropertyValue('--chat-viewport-height')).toBe(`${window.innerHeight}px`);
  action.destroy();
});
