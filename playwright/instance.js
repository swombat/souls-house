import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
const executable = fileURLToPath(new URL('../bin/instance', import.meta.url));
export const instance = JSON.parse(
  execFileSync(executable, ['show'], {
    env: { ...process.env, RAILS_ENV: 'test' },
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'inherit'],
  })
);
