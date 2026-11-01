#!/usr/bin/env node
// The E2E spec files of shard SHARD of TOTAL, one path per line:
//
//   bun run test --no-deps --workers=1 $(node scripts/e2e-shard.mjs 2 5)
//
// Files are balanced by the seconds in test/ci/e2e_timings.json (see
// scripts/e2e-test-timings.mjs): longest file first onto the lightest shard,
// ties by name, so every job computes the same plan. A file with no recorded
// time counts as the median. Playwright's own --shard cuts the alphabetical
// list into equal numbers of tests, which left one of three shards at 389 s
// and another at 253 s.
import { readdirSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
export const SPEC_DIR = 'test/e2e';
export const TIMINGS = 'test/ci/e2e_timings.json';

export function specFiles(dir = path.join(ROOT, SPEC_DIR)) {
  return readdirSync(dir)
    .filter((name) => name.endsWith('.spec.js'))
    .sort();
}

export function readTimings(file = path.join(ROOT, TIMINGS)) {
  return JSON.parse(readFileSync(file, 'utf8'));
}

// [{ files: [...], seconds }] for every shard, in shard order.
export function plan(total, files = specFiles(), timings = readTimings()) {
  if (!Number.isInteger(total) || total < 1) throw new Error(`TOTAL must be a positive integer, not ${total}`);
  const known = Object.values(timings).sort((a, b) => a - b);
  const median = known.length ? known[Math.floor(known.length / 2)] : 1;
  const seconds = (file) => timings[file] ?? median;
  const byName = (a, b) => (a < b ? -1 : a > b ? 1 : 0);
  const shards = Array.from({ length: total }, () => ({ files: [], seconds: 0 }));
  for (const file of [...files].sort((a, b) => seconds(b) - seconds(a) || byName(a, b))) {
    const lightest = shards.reduce((best, shard) => (shard.seconds < best.seconds ? shard : best));
    lightest.files.push(file);
    lightest.seconds += seconds(file);
  }
  return shards.map((shard) => ({ files: shard.files.sort(byName), seconds: shard.seconds }));
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [shard, total] = process.argv.slice(2).map(Number);
  if (!(Number.isInteger(total) && total >= 1 && Number.isInteger(shard) && shard >= 1 && shard <= total)) {
    console.error('Usage: node scripts/e2e-shard.mjs SHARD TOTAL   (1 <= SHARD <= TOTAL)');
    process.exit(2);
  }
  const { files, seconds } = plan(total)[shard - 1];
  if (files.length === 0) {
    console.error(`E2E shard ${shard}/${total} has no files: more shards than spec files`);
    process.exit(1);
  }
  console.error(`E2E shard ${shard}/${total}: ${files.length} files, ${Math.round(seconds)} s of recorded test time`);
  for (const file of files) console.log(`${SPEC_DIR}/${file}`);
}
