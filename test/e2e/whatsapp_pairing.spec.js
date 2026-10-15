import { createHmac, randomBytes } from 'node:crypto';
import { existsSync, readFileSync, statSync } from 'node:fs';
import { expect, test } from '@playwright/test';
import QRCode from 'qrcode';

// The owner pairs WhatsApp on the integrations page. No connector and no
// WhatsApp: the test signs the connector's events with the connection's
// callback secret (CommsSignature) and posts them to the real events
// endpoint, then checks what the owner's page shows.

const QR_OPTIONS = { errorCorrectionLevel: 'M' };
const QR_MARGIN = 1;

// Reads the dark and light modules off the rendered <img> and compares them
// with the modules the code should encode: this checks which code the owner
// can actually scan, not just that some image is there.
async function expectQrShows(qr, code) {
  const expected = QRCode.create(code, QR_OPTIONS).modules;
  const want = Array.from(expected.data, (bit) => (bit ? 1 : 0)).join('');
  await expect
    .poll(
      () =>
        qr.evaluate(
          (image, { size, margin }) => {
            if (!image.complete || !image.naturalWidth) return '';
            const canvas = document.createElement('canvas');
            canvas.width = image.naturalWidth;
            canvas.height = image.naturalHeight;
            const context = canvas.getContext('2d');
            context.drawImage(image, 0, 0);
            const pixels = context.getImageData(0, 0, canvas.width, canvas.height).data;
            const step = canvas.width / (size + margin * 2);
            let bits = '';
            for (let row = 0; row < size; row += 1) {
              for (let col = 0; col < size; col += 1) {
                const x = Math.floor((col + margin + 0.5) * step);
                const y = Math.floor((row + margin + 0.5) * step);
                bits += pixels[(y * canvas.width + x) * 4] < 128 ? '1' : '0';
              }
            }
            return bits;
          },
          { size: expected.size, margin: QR_MARGIN }
        ),
      { timeout: 10_000 }
    )
    .toBe(want);
}

function iso(ms) {
  return new Date(ms).toISOString();
}

// Like the connector, every event names its pairing attempt: 1 when the
// connection is created, one more for each restart.
async function sendEvent(request, connection, event) {
  const path = `/internal/comms/connections/${connection.id}/events`;
  const body = JSON.stringify({ attempt: connection.attempt ?? 1, ...event });
  const timestamp = Math.floor(Date.now() / 1000).toString();
  const nonce = randomBytes(16).toString('hex');
  const signed = [connection.id, 'POST', path, timestamp, nonce, body].join('\n');
  const signature = createHmac('sha256', connection.callback_secret).update(signed).digest('hex');
  return request.post(path, {
    data: body,
    headers: {
      'Content-Type': 'application/json',
      'X-Comms-Connection': connection.id,
      'X-Comms-Timestamp': timestamp,
      'X-Comms-Nonce': nonce,
      'X-Comms-Signature': signature,
    },
  });
}

function qrEvent(code, issuedAt, lifetimeMs) {
  return { type: 'pairing.qr', code, issued_at: iso(issuedAt), expires_at: iso(issuedAt + lifetimeMs) };
}

async function logIn(page, email, password) {
  await page.goto('/login');
  await page.getByLabel(/email/i).fill(email);
  await page.getByLabel(/password/i).fill(password);
  await page.getByRole('button', { name: /log in/i }).click();
  await expect(page).toHaveURL(/\/$/);
}

test('the owner scans rotating WhatsApp codes, restarts after expiry and sees the link', async ({
  page,
  request,
}, testInfo) => {
  test.setTimeout(90_000);
  const runId = `whatsapp-${Date.now()}`;
  const response = await request.post('/test/e2e/setup', { data: { run_id: runId, whatsapp: true } });
  expect(response.ok()).toBe(true);
  const setup = await response.json();
  const connection = setup.whatsapp;
  const pairingUrl = `/accounts/${setup.account_param}/service_connections/${connection.id}/pairing`;
  const secret = (label) => `2@e2e-${label}-${randomBytes(12).toString('hex')}`;
  try {
    await logIn(page, setup.primary_user.email, setup.password);
    await page.goto(`/accounts/${setup.account_param}/integrations`);

    const card = page.getByRole('article').filter({ hasText: 'WhatsApp' });
    const pairing = card.getByTestId('whatsapp-pairing');
    const qr = card.getByRole('img', { name: 'WhatsApp pairing QR code' });
    const countdown = card.getByTestId('whatsapp-qr-countdown');
    await expect(pairing).toContainText('Waiting for a pairing code from WhatsApp.');
    await expect(card.getByRole('button', { name: 'Restart pairing' })).toBeVisible();
    // A desktop leads with the QR and offers the phone number instead.
    await expect(card.getByRole('button', { name: 'Use a phone number instead' })).toBeVisible();
    await expect(card.getByLabel('Phone number')).toHaveCount(0);

    // First code.
    const start = Date.now();
    const first = secret('first');
    expect((await sendEvent(request, connection, qrEvent(first, start - 5_000, 60_000))).status()).toBe(204);
    await expect(qr).toBeVisible();
    await expectQrShows(qr, first);
    expect(await qr.evaluate((image) => image.naturalWidth)).toBeGreaterThan(0);
    await expect(card.getByText('Tap Link a device.')).toBeVisible();
    await expect(countdown).toHaveText(/This code expires in 0:5\d\. A new one appears by itself\./);
    await card.screenshot({ path: testInfo.outputPath('whatsapp-qr.png') });

    // The code rotates: the newer one replaces it.
    const second = secret('second');
    const secondIssued = Date.now();
    expect((await sendEvent(request, connection, qrEvent(second, secondIssued, 20_000))).status()).toBe(204);
    await expectQrShows(qr, second);
    await expect(qr).toHaveAttribute('data-issued-at', iso(secondIssued));

    // A delayed older code is refused and never shown.
    const stale = await sendEvent(request, connection, qrEvent(secret('stale'), secondIssued - 2_000, 40_000));
    expect(stale.status()).toBe(409);
    expect((await stale.json()).error).toBe('stale_qr');
    await page.waitForResponse((reply) => reply.url().endsWith('/pairing'));
    await page.waitForResponse((reply) => reply.url().endsWith('/pairing'));
    await expectQrShows(qr, second);

    // The code is in no page prop, history entry or the page's HTML.
    const exposed = await page.evaluate(
      (codes) => {
        const text = document.documentElement.outerHTML + JSON.stringify(window.history.state ?? null);
        return codes.filter((code) => text.includes(code));
      },
      [first, second]
    );
    expect(exposed).toEqual([]);

    // The last code runs out with nothing newer: pairing has timed out and
    // the owner is offered a restart.
    const last = secret('last');
    expect((await sendEvent(request, connection, qrEvent(last, Date.now(), 7_000))).status()).toBe(204);
    await expectQrShows(qr, last);
    await expect(countdown).toHaveText('This code expired. Waiting for a new one.', { timeout: 10_000 });
    await expect(countdown).toHaveText(
      'Pairing timed out: WhatsApp stopped sending codes. Restart pairing for a new one.',
      { timeout: 12_000 }
    );
    await card.screenshot({ path: testInfo.outputPath('whatsapp-expired.png') });
    const restarted = page.waitForResponse((reply) => reply.url().endsWith('/pairing/restart'));
    await card.getByRole('button', { name: 'Restart pairing' }).click();
    expect((await restarted).status()).toBe(200);
    await expect(pairing).toContainText('Waiting for a pairing code from WhatsApp.');
    await expect(qr).toHaveCount(0);

    // The restart is a new attempt: the old attempt's late "connected" (for
    // a device the connector has deleted) is refused, and nothing changes.
    const late = await sendEvent(request, connection, { type: 'status.changed', status: 'connected' });
    expect(late.status()).toBe(409);
    expect((await late.json()).error).toBe('stale_attempt');
    connection.attempt = 2;

    // A fresh code after the restart, then WhatsApp reports the link.
    const fresh = secret('fresh');
    expect((await sendEvent(request, connection, qrEvent(fresh, Date.now(), 60_000))).status()).toBe(204);
    await expectQrShows(qr, fresh);
    const linked = await sendEvent(request, connection, {
      type: 'status.changed',
      seq: 1,
      status: 'connected',
      identity: { user_id: '447700900123', display_name: 'Ada Example' },
    });
    expect(linked.status()).toBe(200);
    const status = card.getByTestId('whatsapp-status');
    await expect(status).toContainText('Linked as');
    await expect(status).toContainText('Ada Example');
    await expect(qr).toHaveCount(0);
    await expect(card.getByTestId('whatsapp-pairing')).toHaveCount(0);
    await expect(card.getByText('Waiting for pairing.')).toHaveCount(0);
    expect((await (await page.request.get(pairingUrl)).json()).qr).toBeNull();
    await card.screenshot({ path: testInfo.outputPath('whatsapp-connected.png') });

    // WhatsApp logs the device out: the owner is asked to pair again.
    expect(
      (await sendEvent(request, connection, { type: 'status.changed', seq: 2, status: 'logged_out' })).status()
    ).toBe(200);
    await page.reload();
    await expect(card.getByTestId('whatsapp-pairing')).toContainText('WhatsApp logged this linked device out.');
    await expect(card.getByRole('button', { name: 'Pair again' })).toBeVisible();
    await card.screenshot({ path: testInfo.outputPath('whatsapp-logged-out.png') });

    await page.setViewportSize({ width: 390, height: 844 });
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
  } finally {
    expect((await request.post('/test/e2e/cleanup', { data: { run_id: runId } })).ok()).toBe(true);
  }
});

test('another member of the account can neither see nor fetch the WhatsApp code', async ({ browser, request }) => {
  const runId = `whatsapp-other-${Date.now()}`;
  const response = await request.post('/test/e2e/setup', { data: { run_id: runId, whatsapp: true } });
  expect(response.ok()).toBe(true);
  const setup = await response.json();
  const connection = setup.whatsapp;
  const code = `2@e2e-private-${randomBytes(12).toString('hex')}`;
  const context = await browser.newContext();
  const page = await context.newPage();
  try {
    expect((await sendEvent(request, connection, qrEvent(code, Date.now(), 60_000))).status()).toBe(204);

    await logIn(page, setup.secondary_user.email, setup.password);
    await page.goto(`/accounts/${setup.account_param}/integrations`);
    await page.waitForLoadState('networkidle');
    await expect(page.getByRole('heading', { name: 'Integrations', level: 1 })).toBeVisible();
    await expect(page.getByRole('img', { name: 'WhatsApp pairing QR code' })).toHaveCount(0);
    await expect(page.getByTestId('whatsapp-pairing')).toHaveCount(0);
    expect(await page.content()).not.toContain(code);

    const pairingUrl = `/accounts/${setup.account_param}/service_connections/${connection.id}/pairing`;
    const fetched = await page.request.get(pairingUrl, { headers: { Accept: 'application/json' } });
    expect(fetched.status()).toBe(404);
    expect(await fetched.text()).not.toContain(code);
  } finally {
    await context.close();
    expect((await request.post('/test/e2e/cleanup', { data: { run_id: runId } })).ok()).toBe(true);
  }
});

// WhatsApp's "Link with phone number instead". The connector is not running
// here, so the test plays it: once the owner has asked for a code, it signs
// and posts the pairing.phone_code event the connector would, naming the
// phone request it answers (the id the connector gets in pair_phone).
function phoneCodeEvent(code, issuedAt, lifetimeMs, requestId) {
  const event = { type: 'pairing.phone_code', code, issued_at: iso(issuedAt), expires_at: iso(issuedAt + lifetimeMs) };
  return requestId ? { ...event, request_id: requestId } : event;
}

// The request id Rails put in the pair_phone command it would have sent.
async function phoneRequest(request, runId) {
  const state = await (await request.post('/test/e2e/state', { data: { run_id: runId } })).json();
  return state.whatsapp?.phone_request;
}

// Both Rails logs of the e2e server, from where they are now.
function logReader() {
  const files = ['log/test.log', 'log/playwright-e2e.log'].filter((file) => existsSync(file));
  const starts = new Map(files.map((file) => [file, statSync(file).size]));
  return () => files.map((file) => readFileSync(file).subarray(starts.get(file)).toString('utf8')).join('\n');
}

const PHONE_DIGITS = '7700900123';

test('on a phone, the owner links WhatsApp with a code instead of a QR', async ({ browser, request }, testInfo) => {
  test.setTimeout(90_000);
  const runId = `whatsapp-phone-${Date.now()}`;
  const response = await request.post('/test/e2e/setup', { data: { run_id: runId, whatsapp: true } });
  expect(response.ok()).toBe(true);
  const setup = await response.json();
  const connection = setup.whatsapp;
  const pairingUrl = `/accounts/${setup.account_param}/service_connections/${connection.id}/pairing`;
  const logs = logReader();
  const context = await browser.newContext({ viewport: { width: 390, height: 844 }, hasTouch: true, isMobile: true });
  const page = await context.newPage();
  try {
    await logIn(page, setup.primary_user.email, setup.password);
    await page.goto(`/accounts/${setup.account_param}/integrations`);
    const card = page.getByRole('article').filter({ hasText: 'WhatsApp' });
    const phoneInput = card.getByLabel('Phone number');

    // A phone leads with the phone number; the QR is one tap away.
    await expect(phoneInput).toBeVisible();
    await expect(card.getByRole('img', { name: 'WhatsApp pairing QR code' })).toHaveCount(0);
    await expect(card.getByRole('button', { name: 'Scan a QR code instead' })).toBeVisible();

    // A code before the owner asked for one is refused.
    const early = await sendEvent(request, connection, phoneCodeEvent('EARL-YCD2', Date.now(), 150_000));
    expect(early.status()).toBe(409);
    expect((await early.json()).error).toBe('stale_phone_code');

    // A number that is not international is refused, nothing asked.
    await phoneInput.fill('07700 900123');
    await card.getByRole('button', { name: 'Get a code' }).click();
    await expect(card.getByRole('status')).toContainText('+ and the country code');

    await phoneInput.fill('+44 7700 900123');
    const requested = page.waitForResponse((reply) => reply.url().endsWith('/pairing/phone'));
    await card.getByRole('button', { name: 'Get a code' }).click();
    expect((await requested).status()).toBe(202);
    await expect(card.getByTestId('whatsapp-phone-requesting')).toHaveText('Asking WhatsApp for a code.');
    const firstRequest = await phoneRequest(request, runId);
    expect(firstRequest).toMatch(/^[0-9a-f]{16}$/);

    // The connector's code arrives: XXXX-XXXX, with WhatsApp's own steps.
    expect(
      (await sendEvent(request, connection, phoneCodeEvent('ABCD2345', Date.now(), 150_000, firstRequest))).status()
    ).toBe(204);
    await expect(card.getByTestId('whatsapp-phone-code')).toHaveText('ABCD-2345');
    const steps = card.getByTestId('whatsapp-phone-steps');
    await expect(steps).toContainText('Open WhatsApp and go to Settings.');
    await expect(steps).toContainText('Tap Linked devices, then Link a device.');
    await expect(steps).toContainText('Tap “Link with phone number instead”.');
    await expect(steps).toContainText('Enter the code ABCD-2345.');
    await expect(card.getByTestId('whatsapp-phone-countdown')).toHaveText(/This code expires in 2:[23]\d\./);
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    await card.screenshot({ path: testInfo.outputPath('whatsapp-phone-code.png') });

    // The number is in no page, prop or history entry; the code is only in
    // the owner's pairing endpoint.
    const exposed = await page.evaluate((digits) => {
      const text = document.documentElement.outerHTML + JSON.stringify(window.history.state ?? null);
      return text.replace(/\s/g, '').includes(digits);
    }, PHONE_DIGITS);
    expect(exposed).toBe(false);

    // The owner sends the number again (a typo fixed, another tab): a new
    // request. The first request's answer, still on its way, is refused, even
    // though it was issued later, and the card keeps waiting for the new one.
    await card.getByRole('button', { name: 'Use a different number' }).click();
    await phoneInput.fill('+44 7700 900124');
    const resent = page.waitForResponse((reply) => reply.url().endsWith('/pairing/phone'));
    await card.getByRole('button', { name: 'Get a code' }).click();
    expect((await resent).status()).toBe(202);
    await expect(card.getByTestId('whatsapp-phone-requesting')).toHaveText('Asking WhatsApp for a code.');
    const secondRequest = await phoneRequest(request, runId);
    expect(secondRequest).toMatch(/^[0-9a-f]{16}$/);
    expect(secondRequest).not.toBe(firstRequest);
    const superseded = await sendEvent(
      request,
      connection,
      phoneCodeEvent('OLDR-EQ23', Date.now(), 150_000, firstRequest)
    );
    expect(superseded.status()).toBe(409);
    expect((await superseded.json()).error).toBe('stale_phone_code');
    await page.waitForTimeout(3_000); // a poll or two
    await expect(card.getByTestId('whatsapp-phone-requesting')).toHaveText('Asking WhatsApp for a code.');
    await expect(card.getByTestId('whatsapp-phone-code')).toHaveCount(0);

    // The current request's code replaces it; it runs out; the owner restarts.
    expect(
      (await sendEvent(request, connection, phoneCodeEvent('WXYZ2345', Date.now(), 6_000, secondRequest))).status()
    ).toBe(204);
    await expect(card.getByTestId('whatsapp-phone-code')).toHaveText('WXYZ-2345');
    await expect(card.getByTestId('whatsapp-phone-countdown')).toHaveText(
      'This code expired. Restart pairing for a new one.',
      { timeout: 12_000 }
    );
    await card.screenshot({ path: testInfo.outputPath('whatsapp-phone-expired.png') });
    const restarted = page.waitForResponse((reply) => reply.url().endsWith('/pairing/restart'));
    await card.getByRole('button', { name: 'Restart pairing' }).click();
    expect((await restarted).status()).toBe(200);
    await expect(phoneInput).toBeVisible();
    await expect(card.getByTestId('whatsapp-phone-code')).toHaveCount(0);

    // The old attempt's code, still in flight, is refused.
    const late = await sendEvent(request, connection, phoneCodeEvent('LATE-CD23', Date.now(), 150_000));
    expect(late.status()).toBe(409);
    expect((await late.json()).error).toBe('stale_attempt');
    connection.attempt = 2;

    // The new attempt: number, code, and WhatsApp reports the link.
    await phoneInput.fill('+44 7700 900123');
    const again = page.waitForResponse((reply) => reply.url().endsWith('/pairing/phone'));
    await card.getByRole('button', { name: 'Get a code' }).click();
    expect((await again).status()).toBe(202);
    const thirdRequest = await phoneRequest(request, runId);
    expect(
      (await sendEvent(request, connection, phoneCodeEvent('NEWC-ODE2', Date.now(), 150_000, thirdRequest))).status()
    ).toBe(204);
    await expect(card.getByTestId('whatsapp-phone-code')).toHaveText('NEWC-ODE2');
    const linked = await sendEvent(request, connection, {
      type: 'status.changed',
      seq: 1,
      status: 'connected',
      identity: { user_id: '447700900555', display_name: 'Ada Example' },
    });
    expect(linked.status()).toBe(200);
    const status = card.getByTestId('whatsapp-status');
    await expect(status).toContainText('Linked as');
    await expect(status).toContainText('Ada Example');
    await expect(card.getByTestId('whatsapp-pairing')).toHaveCount(0);
    const after = await (await page.request.get(pairingUrl)).json();
    expect(after.phone_code).toBeNull();
    await card.screenshot({ path: testInfo.outputPath('whatsapp-phone-linked.png') });

    // Neither the number nor a code reached the Rails logs.
    const written = logs();
    expect(written).toContain('pairing/phone');
    for (const secret of [PHONE_DIGITS, '7700900124', '7700 900123', 'ABCD2345', 'ABCD-2345', 'NEWCODE2']) {
      expect(written).not.toContain(secret);
    }
  } finally {
    await context.close();
    expect((await request.post('/test/e2e/cleanup', { data: { run_id: runId } })).ok()).toBe(true);
  }
});

test('another member of the account can neither see nor fetch the phone code', async ({ browser, request }) => {
  const runId = `whatsapp-phone-other-${Date.now()}`;
  const response = await request.post('/test/e2e/setup', { data: { run_id: runId, whatsapp: true } });
  expect(response.ok()).toBe(true);
  const setup = await response.json();
  const connection = setup.whatsapp;
  const pairingUrl = `/accounts/${setup.account_param}/service_connections/${connection.id}/pairing`;
  const code = `${randomBytes(4).toString('hex').toUpperCase().slice(0, 4)}PRIV`;
  const ownerContext = await browser.newContext({ viewport: { width: 390, height: 844 }, hasTouch: true });
  const memberContext = await browser.newContext({ viewport: { width: 390, height: 844 }, hasTouch: true });
  try {
    const owner = await ownerContext.newPage();
    await logIn(owner, setup.primary_user.email, setup.password);
    await owner.goto(`/accounts/${setup.account_param}/integrations`);
    const ownerCard = owner.getByRole('article').filter({ hasText: 'WhatsApp' });
    await ownerCard.getByLabel('Phone number').fill('+44 7700 900123');
    await ownerCard.getByRole('button', { name: 'Get a code' }).click();
    await expect(ownerCard.getByTestId('whatsapp-phone-requesting')).toBeVisible();
    expect(
      (
        await sendEvent(
          request,
          connection,
          phoneCodeEvent(code, Date.now(), 150_000, await phoneRequest(request, runId))
        )
      ).status()
    ).toBe(204);
    await expect(ownerCard.getByTestId('whatsapp-phone-code')).toHaveText(`${code.slice(0, 4)}-${code.slice(4)}`);

    const member = await memberContext.newPage();
    await logIn(member, setup.secondary_user.email, setup.password);
    await member.goto(`/accounts/${setup.account_param}/integrations`);
    await member.waitForLoadState('networkidle');
    await expect(member.getByRole('heading', { name: 'Integrations', level: 1 })).toBeVisible();
    await expect(member.getByTestId('whatsapp-phone-code')).toHaveCount(0);
    await expect(member.getByLabel('Phone number')).toHaveCount(0);
    expect(await member.content()).not.toContain(code.slice(0, 4) + '-' + code.slice(4));

    const fetched = await member.request.get(pairingUrl, { headers: { Accept: 'application/json' } });
    expect(fetched.status()).toBe(404);
    expect(await fetched.text()).not.toContain(code);
    // Nor can they ask for one, posting as the page itself would.
    const asked = await member.evaluate(async (url) => {
      const token = document.querySelector('meta[name="csrf-token"]')?.getAttribute('content') || '';
      const reply = await fetch(url, {
        method: 'POST',
        credentials: 'same-origin',
        headers: { 'Content-Type': 'application/json', Accept: 'application/json', 'X-CSRF-Token': token },
        body: JSON.stringify({ phone: '+44 7700 900999', attempt: 1 }),
      });
      return reply.status;
    }, `${pairingUrl}/phone`);
    expect(asked).toBe(404);
  } finally {
    await ownerContext.close();
    await memberContext.close();
    expect((await request.post('/test/e2e/cleanup', { data: { run_id: runId } })).ok()).toBe(true);
  }
});

test('on a phone, the pairing opens on its own page, number first, and ends linked', async ({
  browser,
  request,
}, testInfo) => {
  const runId = `whatsapp-link-page-${Date.now()}`;
  const response = await request.post('/test/e2e/setup', { data: { run_id: runId, whatsapp: true } });
  expect(response.ok()).toBe(true);
  const setup = await response.json();
  const connection = setup.whatsapp;
  const context = await browser.newContext({ viewport: { width: 390, height: 844 }, hasTouch: true, isMobile: true });
  const page = await context.newPage();
  try {
    await logIn(page, setup.primary_user.email, setup.password);
    await page.goto(`/accounts/${setup.account_param}/integrations`);
    const card = page.getByRole('article').filter({ hasText: 'WhatsApp' });
    await card.getByTestId('whatsapp-link-page-link').click();
    await expect(page).toHaveURL(
      new RegExp(`/accounts/${setup.account_param}/service_connections/${connection.id}/pairing/link$`)
    );

    // The whole screen is the pairing: the number field is in view without
    // scrolling past anything else.
    await expect(page.getByRole('heading', { name: 'Link WhatsApp' })).toBeVisible();
    const phoneInput = page.getByTestId('whatsapp-link-page').getByLabel('Phone number');
    await expect(phoneInput).toBeInViewport();
    await expect(page.getByRole('button', { name: 'Get a code' })).toBeInViewport();
    await page.screenshot({ path: testInfo.outputPath('whatsapp-link-page.png') });

    const linked = await sendEvent(request, connection, {
      type: 'status.changed',
      seq: 1,
      status: 'connected',
      identity: { user_id: '447700900123', display_name: 'Ada Example' },
    });
    expect(linked.status()).toBe(200);
    await expect(page.getByTestId('whatsapp-link-done')).toContainText('Linked');
    await expect(page.getByRole('link', { name: 'Back to Integrations' })).toBeVisible();
    await expect(page.getByTestId('whatsapp-pairing')).toHaveCount(0);
  } finally {
    await context.close();
    expect((await request.post('/test/e2e/cleanup', { data: { run_id: runId } })).ok()).toBe(true);
  }
});
