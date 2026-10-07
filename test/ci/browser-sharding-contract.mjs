// Listing only: no browser, backend, database or provider request is started.
import { spawnSync } from 'node:child_process';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const home = mkdtempSync(join(tmpdir(), 'browser-shard-contract-'));
const env = {
  PATH: process.env.PATH,
  HOME: home,
  CI: '1',
  SOULSHOUSE_INSTANCE: process.env.SOULSHOUSE_INSTANCE || '9',
};

function listing(suite, shard) {
  const cli =
    suite === 'e2e' ? 'node_modules/@playwright/test/cli.js' : 'node_modules/@playwright/experimental-ct-svelte/cli.js';
  const args = [cli, 'test', '-c', `playwright-${suite}.config.js`, '--list', '--reporter=json', '--workers=1'];
  if (suite === 'e2e') args.push('--no-deps');
  if (shard) args.push(`--shard=${shard}`);
  const result = spawnSync(process.execPath, args, {
    env,
    encoding: 'utf8',
    maxBuffer: 10 * 1024 * 1024,
  });
  assert.equal(result.status, 0, result.stderr || result.stdout);
  const report = JSON.parse(result.stdout);
  assert.deepEqual(report.errors, []);
  assert.equal(report.config.workers, 1);
  const tests = [];
  function visit(suites) {
    for (const suite of suites) {
      for (const spec of suite.specs || []) {
        for (const test of spec.tests) {
          tests.push({
            key: `${spec.id}:${test.projectName}`,
            file: spec.file,
            project: test.projectName,
          });
        }
      }
      visit(suite.suites || []);
    }
  }
  visit(report.suites);
  return tests;
}

try {
  const baseline = listing('e2e');
  const shards = Array.from({ length: 3 }, (_, i) => listing('e2e', `${i + 1}/3`));
  const assigned = shards.flat();
  assert.equal(new Set(assigned.map((test) => test.key)).size, assigned.length, 'Duplicate E2E assignment');
  assert.deepEqual(assigned.map((test) => test.key).sort(), baseline.map((test) => test.key).sort());
  assert(
    baseline.some((test) => test.project === 'admission'),
    'Admission coverage disappeared'
  );
  for (const test of assigned) {
    assert.equal(test.project === 'admission', test.file === 'account_capacity.spec.js');
  }
  // Ordinary E2E files remain whole; single worker serializes admission with
  // the other files on its private backend. No dependency project is replayed.
  for (const file of new Set(baseline.map((test) => test.file))) {
    assert.equal(shards.filter((shard) => shard.some((test) => test.file === file)).length, 1, file);
  }
  const components = listing('ct');
  assert(components.length > 0, 'Component coverage disappeared');
  console.log(
    `Coverage contract: ${baseline.length} E2E tests exactly once across 3 shards; ${components.length} component tests listed.`
  );
} finally {
  rmSync(home, { recursive: true, force: true });
}
