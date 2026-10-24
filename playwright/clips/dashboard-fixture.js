// Deterministic, invented figures for the dashboard clip. Every series is a
// pure function of `p` (0..1), how far the clip has "filled in", so the real
// dashboard page can be mounted frame by frame with growing data.

function rng(seed) {
  let s = seed >>> 0;
  return () => {
    s = (s * 1664525 + 1013904223) >>> 0;
    return s / 2 ** 32;
  };
}

const WEEKS = 26;
const DAYS = 30;
const HOURS = 168;

function isoDay(offset) {
  const d = new Date(Date.UTC(2026, 9, 9) + offset * 86400000);
  return d.toISOString().slice(0, 10);
}

// Reveal the first fraction `p` of a series; the rest stays empty, so lines
// draw from left to right.
function reveal(values, p) {
  const shown = Math.round(values.length * p);
  return values.map((v, i) => (i < shown ? v : null));
}

// Bars rise rather than appear: each day grows in turn.
function rise(values, p) {
  const n = values.length;
  return values.map((v, i) => {
    const local = Math.min(1, Math.max(0, p * (n + 6) - i) / 6);
    return Math.round(v * local);
  });
}

const r = rng(20261009);
const accounts = [];
const humans = [];
const residents = [];
let a = 0;
for (let w = 0; w < WEEKS; w += 1) {
  const pace = Math.round((1 + w * w * 0.045) * (0.7 + r() * 0.6));
  a += pace;
  accounts.push(a);
  humans.push(Math.round(a * 0.96));
  residents.push(Math.round(a * 0.71));
}

const channels = { conversation: [], telegram: [], wake: [], memory: [], other: [] };
for (let d = 0; d < DAYS; d += 1) {
  const scale = 0.35 + (d / DAYS) * 0.9;
  channels.conversation.push(Math.round((40 + r() * 25) * scale));
  channels.telegram.push(Math.round((10 + r() * 8) * scale));
  channels.wake.push(Math.round((22 + r() * 6) * scale));
  channels.memory.push(Math.round((6 + r() * 4) * scale));
  channels.other.push(Math.round((3 + r() * 3) * scale));
}

const cpu = Array.from(
  { length: HOURS },
  (_, h) => Math.round((22 + 14 * Math.sin((((h % 24) - 9) / 24) * 2 * Math.PI) + r() * 7) * 10) / 10
);
const disk = Array.from({ length: DAYS }, (_, d) => (480 + d * 1.6 + r()) * 1024 ** 3);
const backups = Array.from({ length: DAYS }, (_, d) => (21 + d * 0.55) * 1024 ** 3);
const stored = backups.map((b) => b * 0.41);
const onDisk = Array.from({ length: DAYS }, (_, d) => (31 + d * 0.8) * 1024 ** 3);
const dailySpend = Array.from({ length: DAYS }, (_, d) => Math.round((6 + d * 0.5 + r() * 3) * 100) / 100);
const foundingSpend = Array.from({ length: DAYS }, () => Math.round((2.6 + r() * 1.2) * 100) / 100);
const failure = Array.from({ length: DAYS }, () => Math.round((0.008 + r() * 0.014) * 10000) / 10000);

const count = (value, p) => Math.round(value * p);

export function dashboardFixture(p) {
  const last = (series) => series[series.length - 1];
  return {
    generated_at: '2026-10-09T10:30:00Z',
    computed_ms: 640,
    headline: {
      accounts: { value: count(last(accounts), p), added: count(23, p) },
      humans: { value: count(last(humans), p), added: count(22, p) },
      residents: { value: count(last(residents), p), added: count(17, p) },
      active_residents: { value: count(Math.round(last(residents) * 0.82), p), previous: count(61, p) },
      active_humans: { value: count(Math.round(last(humans) * 0.7), p), previous: null },
      founding: { accounts: 4, residents: 11 },
    },
    growth: {
      weeks: Array.from({ length: WEEKS }, (_, w) => isoDay((w - WEEKS + 1) * 7)),
      accounts: reveal(accounts, p),
      humans: reveal(humans, p),
      residents: reveal(residents, p),
    },
    funnel: {
      all_time: [
        count(last(humans), p),
        count(Math.round(last(humans) * 0.74), p),
        count(Math.round(last(humans) * 0.69), p),
      ],
      last_30_days: [count(61, p), count(46, p), count(43, p)],
    },
    activity: {
      days: Array.from({ length: DAYS }, (_, d) => isoDay(d - DAYS + 1)),
      channels: [
        { key: 'conversation', label: 'Conversations' },
        { key: 'telegram', label: 'Telegram' },
        { key: 'wake', label: 'Heartbeats' },
        { key: 'memory', label: 'Memory' },
        { key: 'other', label: 'Other' },
      ],
      growth: Object.fromEntries(Object.entries(channels).map(([k, v]) => [k, rise(v, p)])),
      everyone: Object.fromEntries(
        Object.entries(channels).map(([k, v]) => [
          k,
          rise(
            v.map((x) => x * 2),
            p
          ),
        ])
      ),
    },
    reliability: {
      turns_finished: count(2840, p),
      turns_failed: count(37, p),
      failure_rate: p > 0.05 ? 0.013 : null,
      failure_rate_daily: reveal(failure, p),
      failures_by_kind: { conversation: count(21, p), wake: count(9, p), memory: count(5, p), other: count(2, p) },
      backups_taken: count(1176, p),
      backups_failed: 0,
      oldest_open_failure_at: null,
    },
    costs: {
      window_days: 30,
      pricing_as_of: '2026-09-27',
      public: {
        api_usd: Math.round(dailySpend.reduce((x, y) => x + y, 0) * p * 100) / 100,
        subscription_estimate_usd: 0,
        unpriced_turns: 0,
        active_residents: count(Math.round(last(residents) * 0.82), p),
        per_active_resident_usd: p > 0.05 ? 3.41 : null,
        daily_usd: reveal(dailySpend, p),
      },
      founding: {
        api_usd: Math.round(foundingSpend.reduce((x, y) => x + y, 0) * p * 100) / 100,
        subscription_estimate_usd: Math.round(212 * p),
        unpriced_turns: 0,
        active_residents: 11,
        per_active_resident_usd: p > 0.05 ? 8.95 : null,
        daily_usd: reveal(foundingSpend, p),
      },
    },
    placement: {
      groups: [
        { backend: 'local', location: null, founding: false, residents: count(64, p) },
        { backend: 'local', location: null, founding: true, residents: 11 },
        { backend: 'hetzner_cloud', location: 'fsn1', founding: false, residents: count(9, p) },
        { backend: 'hetzner_cloud', location: 'hel1', founding: false, residents: count(5, p) },
      ],
      vms: [
        { server_type: 'cx23', location: 'fsn1', count: count(9, p) },
        { server_type: 'cx23', location: 'hel1', count: count(5, p) },
      ],
      unresolved_procurements: {},
    },
    backups: {
      logical_bytes: last(backups) * p,
      residents_backed_up: count(89, p),
      largest: [
        ['Juniper', 2.1],
        ['Wren', 1.7],
        ['Ash', 1.3],
        ['Linden', 1.1],
        ['Moss', 0.9],
        ['Fern', 0.8],
        ['Rook', 0.7],
        ['Ivy', 0.6],
      ].map(([name, gb], i) => ({
        name,
        founding: i === 1,
        bytes: gb * 1024 ** 3 * p,
        taken_at: '2026-10-09T04:00:00Z',
      })),
      daily_logical_bytes: reveal(backups, p),
    },
    server: {
      available: true,
      sampled_at: '2026-10-09T10:30:00Z',
      cores: 16,
      load: [3.1 * p, 2.8 * p, 2.4 * p],
      cpu_percent: 27 * p,
      cpu_avg_24h: 24 * p,
      mem_total_bytes: 128 * 1024 ** 3,
      mem_available_bytes: (128 - 41 * p) * 1024 ** 3,
      disk_total_bytes: 1000 * 1024 ** 3,
      disk_used_bytes: last(disk) * p,
      hourly_cpu: reveal(cpu, p),
      hourly_load: [],
      hourly_mem_used: [],
      daily_disk_used: reveal(disk, p),
      busiest_residents: [
        ['Juniper', 14.2, 1.4],
        ['Wren', 11.8, 1.1],
        ['Ash', 9.6, 0.9],
        ['Linden', 7.1, 0.8],
        ['Moss', 5.4, 0.7],
      ].map(([name, c, gb], i) => ({
        name,
        founding: i === 1,
        cpu: Math.round(c * p * 10) / 10,
        mem_bytes: gb * 1024 ** 3,
      })),
      vms: [],
    },
    storage: {
      restic_sampled: true,
      restic_stored_bytes: last(stored) * p,
      restic_objects: count(5400, p),
      restic_usd_per_month: Math.round((last(stored) / 1024 ** 3) * 0.023 * p * 100) / 100,
      s3_usd_per_gb_month: 0.023,
      s3_region: 'eu-west-1',
      restic_daily_bytes: reveal(stored, p),
      disk_bytes: last(onDisk) * p,
      disk_residents_measured: count(75, p),
      disk_daily_bytes: reveal(onDisk, p),
      hetzner_eur_per_month: Math.round(14 * 4.15 * p * 100) / 100,
    },
    founding: [
      { id: 'f1', name: 'The founders', residents: 4 },
      { id: 'f2', name: 'Family', residents: 3 },
      { id: 'f3', name: 'The Nexus', residents: 4 },
    ],
  };
}
