// Run against two owned test backends started with playwright/setup-test-server.sh.
// Uses a single browser context: localhost ports share a cookie jar.
import { chromium, expect } from '@playwright/test';

const urls = process.argv.slice(2);
if (
  urls.length !== 2 ||
  urls.some((url) => {
    const parsed = new URL(url);
    return parsed.protocol !== 'http:' || !['localhost', '127.0.0.1'].includes(parsed.hostname);
  }) ||
  new URL(urls[0]).hostname !== new URL(urls[1]).hostname
) {
  throw new Error('Supply two local test backend URLs using the same hostname');
}
const browser = await chromium.launch();
const context = await browser.newContext();
const runId = `instance-cookies-${Date.now()}`;
const fixtures = [];
try {
  for (const url of urls) {
    const response = await context.request.post(`${url}/test/e2e/setup`, { data: { run_id: runId } });
    expect(response.ok()).toBe(true);
    fixtures.push(await response.json());
  }
  for (let index = 0; index < urls.length; index++) {
    const page = await context.newPage();
    const user = index === 0 ? fixtures[index].primary_user : fixtures[index].secondary_user;
    await page.goto(`${urls[index]}/login`);
    await page.getByLabel(/email/i).fill(user.email);
    await page.getByLabel(/password/i).fill(fixtures[index].password);
    await page.getByRole('button', { name: /log in|sign in/i }).click();
    await expect(page).toHaveURL(`${urls[index]}/`);
  }
  async function currentUser(index) {
    const page = await context.newPage();
    const response = await page.goto(`${urls[index]}/accounts/${fixtures[index].account_id}/chats`);
    expect(response.ok()).toBe(true);
    const email = await page.evaluate(
      () => JSON.parse(document.querySelector('[data-page]').dataset.page).props.user.email_address
    );
    await page.close();
    return email;
  }
  expect(await currentUser(0)).toBe(fixtures[0].primary_user.email);
  expect(await currentUser(1)).toBe(fixtures[1].secondary_user.email);
  const cookies = await context.cookies();
  expect(cookies.filter((cookie) => cookie.name.startsWith('session_id_souls_'))).toHaveLength(2);
  console.log('PASS: one browser stays logged in as different users on two local ports');
  await context.request.delete(`${urls[0]}/logout`);
  expect(await currentUser(1)).toBe(fixtures[1].secondary_user.email);
  console.log('PASS: logging out of one instance leaves the other session intact');
} finally {
  for (const url of urls) {
    await context.request.post(`${url}/test/e2e/cleanup`, { data: { run_id: runId } });
  }
  await browser.close();
}
