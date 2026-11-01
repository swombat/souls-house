#!/usr/bin/env node
// Rewrites test/ci/e2e_timings.json, the seconds per spec file that
// scripts/e2e-shard.mjs balances the CI shards on, from Playwright JSON
// reports (one for the whole suite, or one per shard):
//
//   PLAYWRIGHT_JSON_OUTPUT_NAME=tmp/e2e-report.json bun run test --no-deps --workers=1 --reporter=json
//   node scripts/e2e-test-timings.mjs tmp/e2e-report.json [more reports...]
//
// Every attempt counts: a file that needs its retry on CI costs that time there too.
import { readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { ROOT, TIMINGS } from './e2e-shard.mjs';

const reports = process.argv.slice(2);
if (reports.length === 0) {
  console.error('Usage: node scripts/e2e-test-timings.mjs REPORT.json [REPORT.json...]');
  process.exit(2);
}

const seconds = {};
function visit(suites) {
  for (const suite of suites ?? []) {
    for (const spec of suite.specs ?? []) {
      for (const test of spec.tests) {
        for (const result of test.results) seconds[spec.file] = (seconds[spec.file] ?? 0) + result.duration / 1000;
      }
    }
    visit(suite.suites);
  }
}
for (const report of reports) visit(JSON.parse(readFileSync(report, 'utf8')).suites);

const sorted = Object.fromEntries(
  Object.keys(seconds)
    .sort()
    .map((file) => [file, Math.round(seconds[file] * 10) / 10])
);
writeFileSync(path.join(ROOT, TIMINGS), `${JSON.stringify(sorted, null, 1)}\n`);
const total = Object.values(sorted).reduce((sum, value) => sum + value, 0);
console.error(`${TIMINGS}: ${Object.keys(sorted).length} files, ${Math.round(total)} s of test time`);
