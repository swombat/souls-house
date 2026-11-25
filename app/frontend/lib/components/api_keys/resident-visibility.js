export function partitionResidents(rows) {
  return {
    active: rows.filter((row) => row.resident_active !== false),
    disabled: rows.filter((row) => row.resident_active === false),
  };
}

export function disabledKeyResidentCount(keys) {
  return new Set(keys.filter((key) => key.resident_active === false).map((key) => key.actor.id)).size;
}
