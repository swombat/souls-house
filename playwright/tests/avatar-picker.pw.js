import { test, expect } from '@playwright/experimental-ct-svelte';
import AvatarPicker from '../../app/frontend/lib/components/AvatarPicker.svelte';

// A picture reaches the avatar endpoint four ways: dropped, dropped from another tab (a link),
// pasted (a screenshot or an address), or an address typed in the box. All HTTP is intercepted.

const PATH = '/accounts/1/residents/r1/avatar';

async function capture(page, reply = { status: 200, json: { success: true } }) {
  const calls = [];
  await page.route(`**${PATH}`, async (route) => {
    const request = route.request();
    calls.push({
      method: request.method(),
      contentType: request.headers()['content-type'] || '',
      body: request.postDataBuffer()?.toString('latin1') || '',
    });
    await route.fulfill(reply);
  });
  return calls;
}

function transfer(page, specs) {
  return page.evaluateHandle((specs) => {
    const dt = new DataTransfer();
    for (const [name, type, text] of specs) {
      if (name === null) dt.setData(type, text);
      else dt.items.add(new File([text], name, { type }));
    }
    return dt;
  }, specs);
}

async function paste(page, locator, specs) {
  const dt = await transfer(page, specs);
  return locator.evaluate((node, dt) => {
    const event = new ClipboardEvent('paste', { clipboardData: dt, bubbles: true, cancelable: true });
    node.dispatchEvent(event);
    return event.defaultPrevented;
  }, dt);
}

const props = { uploadPath: PATH, deletePath: PATH };

test('a picture dropped on the box is uploaded as a file', async ({ mount, page }) => {
  const calls = await capture(page);
  await mount(AvatarPicker, { props });
  const zone = page.locator('[data-avatar-dropzone]');

  const dt = await transfer(page, [['me.png', 'image/png', 'PNGDATA']]);
  await zone.dispatchEvent('dragenter', { dataTransfer: dt });
  await expect(zone).toHaveAttribute('data-dragging', '');
  await zone.dispatchEvent('dragover', { dataTransfer: dt });
  await zone.dispatchEvent('drop', { dataTransfer: dt });

  await expect.poll(() => calls.length).toBe(1);
  expect(calls[0].method).toBe('PATCH');
  expect(calls[0].contentType).toContain('multipart/form-data');
  expect(calls[0].body).toContain('name="avatar"; filename="me.png"');
  await expect(zone).not.toHaveAttribute('data-dragging', '');
});

test('an image dragged in from another tab arrives as its address', async ({ mount, page }) => {
  const calls = await capture(page);
  await mount(AvatarPicker, { props });
  const zone = page.locator('[data-avatar-dropzone]');

  const dt = await transfer(page, [[null, 'text/uri-list', 'https://pics.example/face.webp']]);
  await zone.dispatchEvent('dragover', { dataTransfer: dt });
  await zone.dispatchEvent('drop', { dataTransfer: dt });

  await expect.poll(() => calls.length).toBe(1);
  expect(JSON.parse(calls[0].body)).toEqual({ url: 'https://pics.example/face.webp' });
});

test('a pasted screenshot is uploaded; a pasted address anywhere but a text box is fetched', async ({
  mount,
  page,
}) => {
  const calls = await capture(page);
  await mount(AvatarPicker, { props });

  expect(await paste(page, page.locator('body'), [['shot.png', 'image/png', 'PNGDATA']])).toBe(true);
  await expect.poll(() => calls.length).toBe(1);
  expect(calls[0].body).toContain('filename="shot.png"');

  expect(await paste(page, page.locator('body'), [[null, 'text/plain', 'https://pics.example/me.jpg']])).toBe(true);
  await expect.poll(() => calls.length).toBe(2);
  expect(JSON.parse(calls[1].body)).toEqual({ url: 'https://pics.example/me.jpg' });
});

test('pasting an address into the box fetches it at once; Enter fetches a typed one', async ({ mount, page }) => {
  const calls = await capture(page);
  await mount(AvatarPicker, { props });
  const box = page.locator('[data-avatar-url]');

  expect(await paste(page, box, [[null, 'text/plain', ' https://pics.example/a.png ']])).toBe(true);
  await expect.poll(() => calls.length).toBe(1);
  expect(JSON.parse(calls[0].body)).toEqual({ url: 'https://pics.example/a.png' });

  await box.fill('https://pics.example/b.gif');
  await box.press('Enter');
  await expect.poll(() => calls.length).toBe(2);
  expect(JSON.parse(calls[1].body)).toEqual({ url: 'https://pics.example/b.gif' });
});

test('the wrong kind of file is refused before upload, and the server’s refusal is shown', async ({ mount, page }) => {
  const calls = await capture(page, {
    status: 422,
    json: { errors: { avatar: "That address isn't on the public internet" } },
  });
  await mount(AvatarPicker, { props });

  await paste(page, page.locator('body'), [['notes.svg', 'image/svg+xml', '<svg/>']]);
  await expect(page.getByRole('alert')).toContainText('PNG, JPEG, GIF or WebP');
  expect(calls.length).toBe(0);

  await page.locator('[data-avatar-url]').fill('http://10.0.0.1/x.png');
  await page.locator('[data-avatar-fetch]').click();
  await expect.poll(() => calls.length).toBe(1);
  await expect(page.getByRole('alert')).toContainText('public internet');
});

test('a paste into an unrelated text field is left to that field, picture or not', async ({ mount, page }) => {
  const calls = await capture(page);
  await mount(AvatarPicker, { props });
  const field = await page.evaluateHandle(() => {
    const input = document.createElement('input');
    input.type = 'text';
    input.setAttribute('data-testid', 'first-name');
    document.body.appendChild(input);
    const area = document.createElement('div');
    area.contentEditable = 'true';
    area.setAttribute('data-testid', 'editable');
    document.body.appendChild(area);
    return input;
  });
  await field.dispose();

  for (const testId of ['first-name', 'editable']) {
    const target = page.getByTestId(testId);
    // A spreadsheet-style clipboard: text plus a picture of itself.
    expect(
      await paste(page, target, [
        [null, 'text/plain', 'Ada'],
        ['range.png', 'image/png', 'PNGDATA'],
      ])
    ).toBe(false);
    expect(await paste(page, target, [['shot.png', 'image/png', 'PNGDATA']])).toBe(false);
    expect(await paste(page, target, [[null, 'text/plain', 'https://pics.example/me.jpg']])).toBe(false);
  }

  // Typing and pasting text in the field still works as text.
  await page.getByTestId('first-name').fill('Ada Lovelace');
  await expect(page.getByTestId('first-name')).toHaveValue('Ada Lovelace');
  await page.waitForTimeout(200);
  expect(calls.length).toBe(0);
});

test('the drop box takes a paste once clicked', async ({ mount, page }) => {
  const calls = await capture(page);
  await mount(AvatarPicker, { props });
  const zone = page.locator('[data-avatar-dropzone]');
  await zone.focus();
  await expect(zone).toBeFocused();

  expect(await paste(page, zone, [['shot.png', 'image/png', 'PNGDATA']])).toBe(true);
  await expect.poll(() => calls.length).toBe(1);
});
