import { afterEach, beforeEach, expect, test } from 'vitest';
import { keepSidebarScroll, resetSidebarScrollMemory } from './sidebar-scroll';

// jsdom has no layout, so give the scroller and items real-looking geometry.
function scroller({ height = 400, items = 20, rowHeight = 60, activeIndex = null } = {}) {
  const node = document.createElement('div');
  let top = 0;
  Object.defineProperty(node, 'scrollTop', {
    get: () => top,
    set: (value) => {
      top = Math.max(0, Math.min(value, items * rowHeight - height));
    },
  });
  node.getBoundingClientRect = () => ({ top: 0, bottom: height });
  for (let i = 0; i < items; i++) {
    const row = document.createElement('a');
    if (i === activeIndex) row.setAttribute('aria-current', 'page');
    row.getBoundingClientRect = () => ({ top: i * rowHeight - top, bottom: (i + 1) * rowHeight - top });
    node.appendChild(row);
  }
  document.body.appendChild(node);
  return node;
}

function scrollTo(node, top) {
  node.scrollTop = top;
  node.dispatchEvent(new Event('scroll'));
}

beforeEach(() => {
  resetSidebarScrollMemory();
  window.sessionStorage.clear();
  document.body.innerHTML = '';
});

afterEach(() => {
  document.body.innerHTML = '';
});

test('a remounted sidebar comes back where the reader left it', () => {
  const first = scroller();
  const action = keepSidebarScroll(first, 'acct:');
  scrollTo(first, 540);
  action.destroy();
  first.remove();

  const second = scroller({ activeIndex: 12 });
  keepSidebarScroll(second, 'acct:');
  expect(second.scrollTop).toBe(540);
});

test('the position survives a reload through sessionStorage', () => {
  const first = scroller();
  keepSidebarScroll(first, 'acct:');
  scrollTo(first, 300);
  resetSidebarScrollMemory();

  const second = scroller();
  keepSidebarScroll(second, 'acct:');
  expect(second.scrollTop).toBe(300);
});

test('the open conversation is nudged into view when the saved spot hides it', () => {
  const first = scroller();
  keepSidebarScroll(first, 'acct:');
  scrollTo(first, 0);

  const second = scroller({ activeIndex: 15 });
  keepSidebarScroll(second, 'acct:');
  // Row 15 ends at 960; the viewport is 400 tall, so just enough to show it.
  expect(second.scrollTop).toBe(560);
});

test('each room keeps its own position', () => {
  const node = scroller();
  const action = keepSidebarScroll(node, 'acct:main');
  scrollTo(node, 420);
  action.update('acct:other');
  expect(node.scrollTop).toBe(0); // nothing saved for the new room yet: its top
  scrollTo(node, 60);
  action.update('acct:main');
  expect(node.scrollTop).toBe(420);
});

test('a first visit with nothing saved leaves the list at the top', () => {
  const node = scroller({ activeIndex: 2 });
  keepSidebarScroll(node, 'acct:');
  expect(node.scrollTop).toBe(0);
});
