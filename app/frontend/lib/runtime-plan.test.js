import { runtimePlanLine } from './runtime-plan';

const plan = (...statuses) => statuses.map((status, i) => ({ text: `step ${i + 1}`, status }));

test('no plan, no line', () => {
  expect(runtimePlanLine({})).toBeNull();
  expect(runtimePlanLine({ plan: [] })).toBeNull();
  expect(runtimePlanLine(undefined)).toBeNull();
});

test('counts finished steps and names the one being worked on', () => {
  expect(runtimePlanLine({ plan: plan('completed', 'completed', 'in_progress', 'pending') })).toBe('2 of 4 · step 3');
});

test('a dropped step leaves the count', () => {
  expect(runtimePlanLine({ plan: plan('completed', 'cancelled', 'in_progress') })).toBe('1 of 2 · step 3');
});

test('a blocked step says what it is waiting on when nothing else is moving', () => {
  expect(runtimePlanLine({ plan: plan('completed', 'blocked', 'pending') })).toBe('1 of 3 · waiting: step 2');
});

test('settles to the count when every step is done or the plan completed', () => {
  expect(runtimePlanLine({ plan: plan('completed', 'completed') })).toBe('2 of 2');
  expect(runtimePlanLine({ plan: plan('completed', 'cancelled'), plan_status: 'completed' })).toBe('1 of 1');
  expect(runtimePlanLine({ plan: plan('completed', 'pending'), plan_status: 'cancelled' })).toBe('1 of 2 · stopped');
});

test('long step text is shortened for the collapsed line', () => {
  const line = runtimePlanLine({ plan: [{ text: 'x'.repeat(200), status: 'in_progress' }] });
  expect(line.length).toBeLessThan(80);
  expect(line.endsWith('…')).toBe(true);
});
