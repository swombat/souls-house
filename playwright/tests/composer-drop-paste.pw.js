import { test, expect } from '@playwright/experimental-ct-svelte';
import MessageComposer from '../../app/frontend/lib/components/chat/MessageComposer.svelte';
import NewChatComposer from '../../app/frontend/lib/components/chat/NewChatComposer.svelte';

// Files dropped onto the composer, or an image pasted into its text box, join the same
// attachment list the paperclip fills and are sent with the message. All HTTP is intercepted.

const CHAT = 'chat-dp';

async function routes(page) {
  let draft = { content: '', revision: 0 };
  await page.route(`**/accounts/1/chats/${CHAT}/draft`, async (route) => {
    if (route.request().method() === 'PATCH') {
      draft = { content: route.request().postDataJSON().content, revision: draft.revision + 1 };
    }
    await route.fulfill({ json: { draft } });
  });
  const sends = [];
  await page.route(`**/accounts/1/chats/${CHAT}/messages`, async (route) => {
    sends.push(route.request().postDataBuffer()?.toString('latin1') || '');
    await route.fulfill({
      json: { message: { id: 'm1', role: 'user', content: 'x' }, draft: { content: '', revision: 99 } },
    });
  });
  return sends;
}

// A DataTransfer holding real File objects, built in the page.
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

const composerProps = { accountId: 1, chatId: CHAT, userId: 7 };

test('a file dropped on the composer is attached and sent', async ({ mount, page }) => {
  const sends = await routes(page);
  const component = await mount(MessageComposer, { props: composerProps });
  const zone = page.getByTestId('message-composer');

  const dt = await transfer(page, [['notes.txt', 'text/plain', 'hello there']]);
  await zone.dispatchEvent('dragenter', { dataTransfer: dt });
  await expect(zone).toHaveAttribute('data-file-drag', '');
  await zone.dispatchEvent('dragover', { dataTransfer: dt });
  await zone.dispatchEvent('drop', { dataTransfer: dt });
  await expect(zone).not.toHaveAttribute('data-file-drag', '');

  await expect(component.getByText('notes.txt')).toBeVisible();
  await component.getByRole('button', { name: 'Send message' }).click();
  await expect.poll(() => sends.length).toBe(1);
  expect(sends[0]).toContain('filename="notes.txt"');
  expect(sends[0]).toContain('hello there');
});

test('a pasted screenshot is attached with a dated name; pasted text stays text', async ({ mount, page }) => {
  const sends = await routes(page);
  const component = await mount(MessageComposer, { props: composerProps });
  const input = component.getByRole('textbox');

  expect(await paste(page, input, [[null, 'text/plain', 'just words']])).toBe(false);
  await expect(component.getByText(/^Pasted /)).toHaveCount(0);

  expect(await paste(page, input, [['image.png', 'image/png', 'PNGBYTES']])).toBe(true);
  await expect(component.getByText(/^Pasted \d{4}-\d\d-\d\d \d\d\.\d\d\.\d\d\.png$/)).toBeVisible();

  await input.fill('look at this');
  await component.getByRole('button', { name: 'Send message' }).click();
  await expect.poll(() => sends.length).toBe(1);
  expect(sends[0]).toMatch(/filename="Pasted [^"]+\.png"/);
  expect(sends[0]).toContain('PNGBYTES');
});

test('a drag of text inside the page is left alone', async ({ mount, page }) => {
  await routes(page);
  await mount(MessageComposer, { props: composerProps });
  const zone = page.getByTestId('message-composer');
  const dt = await transfer(page, [[null, 'text/plain', 'moved words']]);
  await zone.dispatchEvent('dragenter', { dataTransfer: dt });
  await expect(zone).not.toHaveAttribute('data-file-drag', '');
});

test('the new-conversation composer takes drops and pastes too', async ({ mount, page }) => {
  const component = await mount(NewChatComposer, { props: { accountId: 1, userId: 7 } });
  const zone = page.getByTestId('message-composer');
  const dt = await transfer(page, [['brief.pdf', 'application/pdf', '%PDF']]);
  await zone.dispatchEvent('dragover', { dataTransfer: dt });
  await zone.dispatchEvent('drop', { dataTransfer: dt });
  await expect(component.getByText('brief.pdf')).toBeVisible();

  expect(await paste(page, component.getByRole('textbox'), [['image.png', 'image/png', 'x']])).toBe(true);
  await expect(component.getByText(/^Pasted .*\.png$/)).toBeVisible();
  await expect(component.getByRole('button', { name: 'Start conversation' })).toBeEnabled();
});
