import { describe, expect, it } from 'vitest';
import { disabledKeyResidentCount, partitionResidents } from './resident-visibility';

describe('resident visibility', () => {
  it('hides only explicitly disabled rows, retaining legacy rows as active', () => {
    const rows = [{ id: 1 }, { id: 2, resident_active: true }, { id: 3, resident_active: false }];
    expect(partitionResidents(rows)).toEqual({ active: rows.slice(0, 2), disabled: [rows[2]] });
    expect(partitionResidents([])).toEqual({ active: [], disabled: [] });
  });

  it('counts disabled residents rather than their keys, using actor ids', () => {
    const keys = [
      { id: 1, actor: { id: 10 }, resident_active: false },
      { id: 2, actor: { id: 10 }, resident_active: false },
      { id: 3, actor: { id: 11 }, resident_active: false },
      { id: 4, actor: { id: 12 }, resident_active: true },
      { id: 5, actor: { id: 13 } },
    ];
    expect(disabledKeyResidentCount(keys)).toBe(2);
    expect(disabledKeyResidentCount([])).toBe(0);
  });
});
