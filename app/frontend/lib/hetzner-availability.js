// Drawing for Site Admin → Hetzner availability. Kept free of Svelte so it
// can be tested directly.

// A check is expected every five minutes; a longer silence than this between
// two checks is drawn as a gap ("we couldn't check"), not carried across.
export const MAX_GAP_MS = 12 * 60 * 1000;

// Both members of each pair have this size (Hetzner's cost-optimized catalog).
export const PAIR_SIZES = {
  'CX23 + CAX11': '2 vCPU / 4 GB RAM / 40 GB NVMe',
  'CX33 + CAX21': '4 vCPU / 8 GB RAM / 80 GB NVMe',
  'CX43 + CAX31': '8 vCPU / 16 GB RAM / 160 GB NVMe',
  'CX53 + CAX41': '16 vCPU / 32 GB RAM / 320 GB NVMe',
};

// SVG path for a 0/1 step line. points are [isoTime, 1 | 0 | null], oldest
// first; x runs from start to end (ms), y is 1 at the top. A null value, or a
// silence longer than MAX_GAP_MS, breaks the line.
export function stepPath(points, start, end, width, height, { pad = 3, now = end } = {}) {
  const span = Math.max(1, end - start);
  const x = (ms) => Math.min(width, Math.max(0, ((ms - start) / span) * width));
  const y = (value) => (value ? pad : height - pad);
  const parts = [];
  let open = false;

  points.forEach(([iso, value], index) => {
    const at = Date.parse(iso);
    if (value === null || value === undefined) {
      open = false;
      return;
    }
    const next = points[index + 1];
    const nextAt = next ? Date.parse(next[0]) : null;
    // A point holds until the next check, or for one check interval when it
    // is the latest, or the one before a gap.
    const until = nextAt !== null && nextAt - at <= MAX_GAP_MS ? nextAt : Math.min(now, at + 5 * 60 * 1000);
    const command = open ? 'L' : 'M';
    parts.push(`${command}${x(at).toFixed(1)},${y(value)}`, `L${x(until).toFixed(1)},${y(value)}`);
    open = nextAt !== null && nextAt - at <= MAX_GAP_MS;
  });

  return parts.join(' ');
}

// Share of checked points that were 1, or null when none were checked.
export function availableShare(points) {
  const checked = points.filter(([, value]) => value !== null && value !== undefined);
  if (!checked.length) return null;
  return checked.filter(([, value]) => value === 1).length / checked.length;
}
