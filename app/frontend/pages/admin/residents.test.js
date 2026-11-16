import { render } from '@testing-library/svelte';
import Residents from './residents.svelte';

let n = 0;
const day = (counts) => ({
  date: `2026-11-${String(++n).padStart(2, '0')}`,
  heartbeat: 0,
  memory: 0,
  chat: 0,
  other: 0,
  conversation: 0,
  telegram: 0,
  ...counts,
});
const resident = (id, name, activity) => ({
  id,
  name,
  active: true,
  deprecated: false,
  account_name: 'Acct',
  hosting: { kind: 'local', state: 'ready' },
  activity,
});

test('orders residents by the last 14 days of activity, runs first and posts breaking ties', () => {
  const { container } = render(Residents, {
    residents: [
      resident('a', 'Quietone', [day({})]),
      resident('b', 'Busyone', [day({ heartbeat: 3, chat: 4 }), day({ memory: 2 })]),
      resident('c', 'Chattyone', [day({ chat: 2 }), day({ conversation: 9 })]),
      resident('d', 'Middleone', [day({ other: 2 })]),
    ],
  });
  const text = container.textContent;
  const order = ['Busyone', 'Chattyone', 'Middleone', 'Quietone'].map((name) => text.indexOf(name));
  expect(order.every((at) => at >= 0)).toBe(true);
  expect([...order].sort((x, y) => x - y)).toEqual(order);
});
