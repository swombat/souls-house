import { createHash } from 'node:crypto';
import { expect, test } from '@playwright/test';

// Parse the served WAV, rather than trusting a duration or comparing against
// another invocation of the same server cutter.
function pcmFromWav(bytes) {
  expect(bytes.toString('ascii', 0, 4)).toBe('RIFF');
  expect(bytes.toString('ascii', 8, 12)).toBe('WAVE');
  let pcm;
  let format;
  for (let offset = 12; offset + 8 <= bytes.length; ) {
    const kind = bytes.toString('ascii', offset, offset + 4);
    const size = bytes.readUInt32LE(offset + 4);
    const body = bytes.subarray(offset + 8, offset + 8 + size);
    if (kind === 'fmt ') {
      format = {
        encoding: body.readUInt16LE(0),
        channels: body.readUInt16LE(2),
        rate: body.readUInt32LE(4),
        bits: body.readUInt16LE(14),
      };
    }
    if (kind === 'data') pcm = body;
    offset += 8 + size + (size % 2);
  }
  expect(format).toEqual({ encoding: 1, channels: 1, rate: 16000, bits: 16 });
  expect(pcm).toBeDefined();
  return pcm;
}

async function login(page, setup) {
  await page.goto('/login');
  await page.getByLabel(/email/i).fill(setup.primary_user.email);
  await page.getByLabel(/password/i).fill(setup.password);
  await page.getByRole('button', { name: /log in/i }).click();
  await expect(page).toHaveURL(/\/$/);
}

for (const device of [
  { name: 'desktop Chromium', viewport: { width: 1440, height: 1000 }, isMobile: false, hasTouch: false },
  { name: 'mobile viewport Chromium', viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true },
]) {
  test.describe(device.name, () => {
    test.use({ viewport: device.viewport, isMobile: device.isMobile, hasTouch: device.hasTouch });

    test('real stored montage playback gates confirmation; exclusion and reinclusion survive reload', async ({
      page,
      request,
    }, testInfo) => {
      test.setTimeout(90_000);
      const runId = `voice-samples-${device.isMobile ? 'mobile' : 'desktop'}-${Date.now()}`;
      const setupResponse = await request.post('/test/e2e/setup', { data: { run_id: runId } });
      expect(setupResponse.ok()).toBe(true);
      const setup = await setupResponse.json();
      try {
        const fixtureResponse = await request.post('/test/e2e/field_voice_sample_fixture', {
          data: { account_id: setup.account_id },
        });
        expect(fixtureResponse.ok(), await fixtureResponse.text()).toBe(true);
        const fixture = await fixtureResponse.json();
        const voicesPath = `/accounts/${setup.account_param}/field/voices`;
        const samplesPath = `${voicesPath}/${fixture.voice_param}/samples`;
        const samplePath = `${samplesPath}/${fixture.speaker_param}`;
        const audioPath = `${samplePath}/audio`;
        const patches = [];
        page.on('request', (req) => {
          if (req.method() === 'PATCH' && new URL(req.url()).pathname === samplePath) {
            patches.push(req.postDataJSON());
          }
        });
        const isList = (response) =>
          new URL(response.url()).pathname === samplesPath && response.request().method() === 'GET';
        const sample = page.getByTestId('voice-sample');
        const inclusion = sample.getByTestId('sample-inclusion');
        const accept = sample.getByTestId('sample-accept');
        const reject = sample.getByTestId('sample-reject');
        const audio = page.getByTestId('sample-audio');
        const checkList = async (response) => {
          // The page's own list request must succeed; its contents are read
          // through the same session, since Chromium may drop a captured body.
          expect((await response).ok()).toBe(true);
          const listed = await page.request.get(samplesPath, { headers: { Accept: 'application/json' } });
          expect(listed.ok()).toBe(true);
          const body = await listed.json();
          expect(body.samples).toHaveLength(1);
          expect(body.samples[0]).toMatchObject({
            id: fixture.speaker_param,
            digest: fixture.digest,
            segments: fixture.segments,
            duration_ms: fixture.duration_ms,
            source_current: true,
          });
          if (body.samples[0].included) expect(body.print).not.toBe('No fingerprint');
          else expect(body.print).toBe('No fingerprint');
          // The roster opens the speaker: on a phone the list gives way to the detail.
          if (!(await page.getByTestId('voice-detail').isVisible())) await page.getByTestId('voice-row').click();
          await expect(page.getByTestId('voice-detail')).toBeVisible();
          await expect(sample).toHaveCount(1);
          return body.samples[0];
        };
        const reloadSamples = async () => {
          // A change refetches the list (and the roster); let those settle so the
          // response awaited is the reloaded page's, not one the reload discarded.
          await page.waitForLoadState('networkidle');
          const response = page.waitForResponse(isList);
          await page.reload();
          return checkList(response);
        };
        const mutate = async (button, included, state) => {
          const response = page.waitForResponse(
            (res) => new URL(res.url()).pathname === samplePath && res.request().method() === 'PATCH'
          );
          await button.click();
          expect((await response).ok()).toBe(true);
          await expect(inclusion).toHaveText(state);
          expect(patches.at(-1)).toEqual({ included, digest: fixture.digest });
        };

        await login(page, setup);
        const firstList = page.waitForResponse(isList);
        await page.goto(voicesPath);
        if (!device.isMobile) {
          await expect(
            page.getByRole('navigation', { name: 'Account settings' }).getByRole('link', { name: 'Voices' })
          ).toHaveAttribute('aria-current', 'page');
        }
        expect(await checkList(firstList)).toMatchObject({ included: true, confirmed: false, state: 'review' });
        await expect(inclusion).toHaveText('Needs review');
        await expect(sample).toContainText('0:03 · 2 spans');
        await expect(sample.getByTitle('Source spans: 0.0s–1.0s, 2.0s–3.5s')).toHaveCount(1);
        await expect(accept).toBeDisabled();

        // The authenticated media and a separate byte range go through the
        // real controller; no page.route or fabricated media events.
        const audioUrl = new URL(`${audioPath}?digest=${encodeURIComponent(fixture.digest)}`, page.url());
        const full = await page.request.get(audioUrl.href);
        expect(full.status()).toBe(200);
        expect(full.headers()['content-type']).toMatch(/^audio\/wav/);
        expect(full.headers()['content-disposition']).toMatch(/^inline;/);
        expect(full.headers()['accept-ranges']).toBe('bytes');
        const bytes = await full.body();
        const pcm = pcmFromWav(bytes);
        expect(pcm.length).toBe(fixture.pcm_bytes);
        expect(createHash('sha256').update(pcm).digest('hex')).toBe(fixture.pcm_sha256);
        const range = await page.request.get(audioUrl.href, { headers: { Range: 'bytes=0-127' } });
        expect(range.status()).toBe(206);
        expect(range.headers()['content-range']).toBe(`bytes 0-127/${bytes.length}`);
        expect(await range.body()).toEqual(bytes.subarray(0, 128));
        const anonymous = await request.get(audioUrl.href, { maxRedirects: 0 });
        expect(anonymous.status()).toBe(302);
        expect(anonymous.headers().location).toMatch(/\/login$/);
        await expect(accept).toBeDisabled(); // Downloading is not listening.

        await audio.evaluate((element) => {
          element.dataset.playEvents = '0';
          element.dataset.endedEvents = '0';
          element.addEventListener('play', () => {
            element.dataset.playEvents = String(Number(element.dataset.playEvents) + 1);
          });
          element.addEventListener('ended', () => {
            element.dataset.endedEvents = String(Number(element.dataset.endedEvents) + 1);
          });
        });
        const mediaResponse = page.waitForResponse((res) => new URL(res.url()).pathname === audioPath);
        // A real tap on the row's play button; no play(), seeking or dispatched events.
        await sample.getByTestId('sample-play').click();
        const media = await mediaResponse;
        expect([200, 206]).toContain(media.status());
        expect(media.headers()['content-type']).toMatch(/^audio\/wav/);
        if (media.status() === 206) expect(media.headers()['content-range']).toMatch(/^bytes \d+-\d+\/\d+$/);
        expect(new URL(media.url()).searchParams.get('digest')).toBe(fixture.digest);
        await expect(audio).toHaveAttribute('data-play-events', '1');
        await expect.poll(() => audio.evaluate((element) => element.currentTime)).toBeGreaterThan(0.1);
        await expect(accept).toBeDisabled();
        await expect(audio).toHaveAttribute('data-ended-events', '1');
        expect(await audio.evaluate((element) => element.duration)).toBeCloseTo(2.5, 2);
        await expect(accept).toBeEnabled();

        await mutate(accept, true, 'Confirmed');
        expect(await reloadSamples()).toMatchObject({ included: true, confirmed: true, state: 'confirmed' });
        await expect(inclusion).toHaveText('Confirmed');
        await expect(inclusion).toHaveAttribute('title', /^Confirmed by /);
        await expect(accept).toHaveCount(0);
        await mutate(reject, false, 'Removed · was confirmed');
        expect(await reloadSamples()).toMatchObject({ included: false, confirmed: true, state: 'removed' });
        await expect(inclusion).toHaveText('Removed · was confirmed');
        await page.screenshot({ path: testInfo.outputPath('sample-excluded.png'), fullPage: true });
        // A sample confirmed before can come back without replaying it.
        await expect(accept).toBeEnabled();
        await mutate(accept, true, 'Confirmed');
        expect(await reloadSamples()).toMatchObject({ included: true, confirmed: true, state: 'confirmed' });
        expect(patches.map((patch) => patch.included)).toEqual([true, false, true]);
        await page.screenshot({ path: testInfo.outputPath('sample-reincluded.png'), fullPage: true });
        expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
      } finally {
        expect((await request.post('/test/e2e/cleanup', { data: { run_id: runId } })).ok()).toBe(true);
      }
    });
  });
}
