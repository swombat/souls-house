import { STATUS_CREATURES, STATUS_STAGES, statusCreatureMarkup } from './status-creatures';

const FAMILIES = ['rabbit', 'flame', 'wisp', 'bird', 'cat', 'seed', 'drop', 'jelly', 'bat', 'lantern', 'ripple', 'roof'];

test('the twelve families the server can pick each have all three poses', () => {
  expect(Object.keys(STATUS_CREATURES).sort()).toEqual([...FAMILIES].sort());
  for (const family of FAMILIES) {
    for (const stage of STATUS_STAGES) {
      const markup = statusCreatureMarkup(family, stage);
      expect(markup, `${family} ${stage}`).toMatch(/^</);
      expect(markup).not.toMatch(/<script|on[a-z]+=|href=/i);
    }
  }
});

test('an unknown family or stage draws nothing', () => {
  expect(statusCreatureMarkup('snail', 'here')).toBeNull();
  expect(statusCreatureMarkup('cat', 'queued')).toBeNull();
});
