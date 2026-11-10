// The companion names disks by a hashed key ("linux-volume:ed42…"), never a
// path. These turn a key into what the Computers page shows.

export const ACCESS_RANK = { off: 0, read: 1, write: 2 };
export const ACCESS_LABEL = { off: 'Off', read: 'Read only', write: 'Read and write' };

export function volumeLabel(key) {
  const [kind, hash = ''] = String(key).split(':');
  const name = { 'linux-volume': 'Linux disk', 'darwin-volume': 'Mac disk' }[kind] ?? kind;
  return { name, id: hash.slice(0, 8) };
}

export function diskName(key) {
  const label = volumeLabel(key);
  return label.id ? `${label.name} ${label.id}` : label.name;
}

// Each folder this resident has, plus each the computer says it allows.
// The computer's own ceiling is the most it can offer; anything already
// granted can always be lowered or turned off, even if it's not listed.
export function folderRows(device, resident) {
  const allowed = device.ceiling?.residents?.[resident.id] ?? [];
  const rows = new Map();
  for (const v of allowed) rows.set(v.volume, { volume: v.volume, current: 'off', ceiling: v.access });
  for (const v of resident.volumes) {
    const row = rows.get(v.volume) ?? { volume: v.volume, ceiling: 'off' };
    rows.set(v.volume, { ...row, current: v.access });
  }
  return [...rows.values()].sort((a, b) => a.volume.localeCompare(b.volume));
}

export function offered(row, access) {
  return ACCESS_RANK[access] <= ACCESS_RANK[row.current] || ACCESS_RANK[access] <= ACCESS_RANK[row.ceiling];
}
