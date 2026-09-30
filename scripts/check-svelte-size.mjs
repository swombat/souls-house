import { readdirSync, readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = fileURLToPath(new URL('../app/frontend/', import.meta.url));
let checked = 0;
let warnings = 0;
let failures = 0;
function visit(directory) {
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const file = path.join(directory, entry.name);
    const relative = path.relative(root, file).split(path.sep).join('/');
    if (relative === 'lib/components/shadcn' || relative === 'test') continue;
    if (entry.isDirectory()) {
      visit(file);
      continue;
    }
    if (!file.endsWith('.svelte')) continue;
    const source = readFileSync(file, 'utf8');
    const lines = source ? source.replace(/\n$/, '').split('\n').length : 0;
    const page = relative.startsWith('pages/') && relative !== 'pages/chats/ChatList.svelte';
    const review = page ? 300 : 200;
    const ceiling = page ? 500 : 300;
    checked++;
    if (lines > ceiling) {
      failures++;
      console.error(`FAIL ${relative}: ${lines} lines (ceiling ${ceiling})`);
    } else if (lines > review) {
      warnings++;
      console.warn(`REVIEW ${relative}: ${lines} lines (review above ${review})`);
    }
  }
}
visit(root);
console.log(`${checked} application Svelte files; ${warnings} review warnings; ${failures} ceiling violations.`);
process.exitCode = failures ? 1 : 0;
