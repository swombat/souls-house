import { render, cleanup, waitFor } from '@testing-library/svelte';
import { afterEach, expect, test } from 'vitest';
import MessageBubble from './MessageBubble.svelte';

afterEach(cleanup);

const mathSelector = '[data-streamdown-inline-math], [data-streamdown-block-math]';

for (const role of ['user', 'assistant']) {
  for (const streaming of [false, true]) {
    for (const content of [
      'A real bug I found and fixed: the model keys page read its props once from $page.props, so after a save the badges stayed "Not set". The e2e caught it. It\'s now $props().',
      "One small thing, not blocking: show.svelte seeds the name field once, with $state(account.name). If another member renames the account while the page is open, sync updates the account prop but the field keeps the old name. Your spec doesn't hit this, because every path either reloads or arrives fresh from the convert redirect. If you want it in this merge, it's a three-line $effect. Otherwise I'll leave it for later.",
      '$page.props contains shared props; $props() reads local props.',
      '$state(account.name) holds the name; $effect watches it.',
      'Use $page.props, $props(), $state(account.name), and $effect.',
      'Read $MIRA_ROOT/secrets/example.json, then $HOME/bin.',
      'Use $state(account.name)',
      '$effect',
      '$page.props...$props()',
      '$state(account.name)...$effect',
      '$ x$ and $x $ and $ x $',
      'It costs $5, or $10. The price range is $5 to $10.',
      String.raw`Escaped \$page.props and \$props(), with \$x\^2\$ left literal.`,
    ]) {
      test(`${role} ${streaming ? 'streaming' : 'completed'} keeps literal dollars: ${content}`, () => {
        const { container } = render(MessageBubble, {
          message: { role, content, streaming, created_at: '2026-09-26T12:00:00Z' },
        });
        expect(container.querySelector(mathSelector)).toBeNull();
        expect(container.textContent).toContain(content.replaceAll('\\$', '$').replaceAll('\\^', '^'));
      });
    }

    test(`${role} ${streaming ? 'streaming' : 'completed'} rejects single-dollar closers followed by identifiers`, () => {
      const { container } = render(MessageBubble, {
        message: {
          role,
          content: '$x$identifier and $y$_suffix_ and $z$2',
          streaming,
          created_at: '2026-09-26T12:00:00Z',
        },
      });
      expect(container.querySelector(mathSelector)).toBeNull();
      expect(container.textContent).toContain('$x$identifier and $y$suffix and $z$2');
    });

    test(`${role} ${streaming ? 'streaming' : 'completed'} keeps dollar identifiers inside code spans`, () => {
      const code = '$page.props ... $props() and $state(account.name) ... $effect';
      const { container } = render(MessageBubble, {
        message: { role, content: `Use \`${code}\` here.`, streaming, created_at: '2026-09-26T12:00:00Z' },
      });
      expect(container.querySelector('code')?.textContent).toBe(code);
      expect(container.querySelector(mathSelector)).toBeNull();
    });

    test(`${role} ${streaming ? 'streaming' : 'completed'} does not cross a code span to find a math closer`, () => {
      const { container } = render(MessageBubble, {
        message: { role, content: '$value and `$props()`.', streaming, created_at: '2026-09-26T12:00:00Z' },
      });
      expect(container.querySelector('code')?.textContent).toBe('$props()');
      expect(container.querySelector(mathSelector)).toBeNull();
    });

    for (const expression of ['$x^2$', '$f(x)$', '$a/b$', '$x_i$', '$x + y$', '$2+2$', '$$ x^2 $$']) {
      test(`${role} ${streaming ? 'streaming' : 'completed'} renders genuine math: ${expression}`, async () => {
        const { container } = render(MessageBubble, {
          message: { role, content: `The result is ${expression}.`, streaming, created_at: '2026-09-26T12:00:00Z' },
        });
        expect(container.querySelectorAll(mathSelector)).toHaveLength(1);
        await waitFor(() => expect(container.querySelector('.katex')).not.toBeNull());
      });
    }
  }
}

test('streaming identifier prefixes stay literal through completion', async () => {
  const message = { role: 'assistant', streaming: true, created_at: '2026-09-26T12:00:00Z' };
  const { container, rerender } = render(MessageBubble, { message: { ...message, content: '$' } });
  for (const content of [
    '$',
    '$p',
    '$page',
    '$page.props',
    '$page.props ... $',
    '$page.props ... $props',
    '$page.props ... $props()',
    '$state',
    '$state(account.name)',
    '$state(account.name) ... $effect',
  ]) {
    await rerender({ message: { ...message, content } });
    expect(container.querySelector(mathSelector)).toBeNull();
    expect(container.textContent).toContain(content);
  }
  const content = '$state(account.name) ... $effect';
  await rerender({ message: { ...message, content, streaming: false } });
  expect(container.querySelector(mathSelector)).toBeNull();
  expect(container.textContent).toContain(content);
});

test('single-dollar math waits for an authored closer while streaming', async () => {
  const message = { role: 'assistant', streaming: true, created_at: '2026-09-26T12:00:00Z' };
  const { container, rerender } = render(MessageBubble, { message: { ...message, content: '$x^2' } });
  expect(container.textContent).toContain('$x^2');
  expect(container.querySelector(mathSelector)).toBeNull();
  await rerender({ message: { ...message, content: '$x^2$' } });
  expect(container.querySelectorAll(mathSelector)).toHaveLength(1);
});

for (const content of ['The result is $$x^2', '$$\nx^2']) {
  test(`streaming still repairs explicitly double-dollar math: ${content}`, async () => {
    const { container } = render(MessageBubble, {
      message: { role: 'assistant', content, streaming: true, created_at: '2026-09-26T12:00:00Z' },
    });
    expect(container.querySelectorAll(mathSelector)).toHaveLength(1);
    await waitFor(() => expect(container.querySelector('.katex')).not.toBeNull());
  });
}

test('math may contain an escaped dollar without closing early', async () => {
  const { container } = render(MessageBubble, {
    message: {
      role: 'assistant',
      content: String.raw`The result is $x + \$ + y$.`,
      created_at: '2026-09-26T12:00:00Z',
    },
  });
  expect(container.querySelectorAll(mathSelector)).toHaveLength(1);
  await waitFor(() => expect(container.querySelector('.katex')).not.toBeNull());
});

for (const role of ['user', 'assistant']) {
  test(`${role} completed prose does not invent a closing math delimiter`, () => {
    const content = 'Stored in $MIRA_ROOT/secrets/example.json for my own machines. Keep these words spaced.';
    const { container } = render(MessageBubble, {
      message: { role, content, created_at: '2026-09-26T12:00:00Z' },
    });
    expect(container.textContent).toContain(content);
    expect(container.querySelector(mathSelector)).toBeNull();
    expect(container.querySelector('.katex')).toBeNull();
  });
}

test('completed messages still render deliberately delimited math', async () => {
  const { container } = render(MessageBubble, {
    message: { role: 'assistant', content: 'The result is $x^2$.', created_at: '2026-09-26T12:00:00Z' },
  });
  await waitFor(() => expect(container.querySelector('.katex')).not.toBeNull());
});

test('streaming messages still complete unfinished formatting', () => {
  const { container } = render(MessageBubble, {
    message: { role: 'assistant', content: '**Arriving words', streaming: true, created_at: '2026-09-26T12:00:00Z' },
  });
  expect(container.querySelector('strong')?.textContent).toBe('Arriving words');
});

test('ordinary grouped sections keep independent Markdown, files, tools and voice controls', async () => {
  const first = { id: 'a', role: 'assistant', content: '```text\nunclosed', created_at: '2026-09-28T08:00:00Z' };
  const second = {
    id: 'b',
    role: 'assistant',
    content: '**Checked.**',
    created_at: '2026-09-28T08:02:03Z',
    files_json: [{ id: 'file', filename: 'report.txt', content_type: 'text/plain', url: '/report.txt' }],
    tools_used: ['web_search'],
    voice_available: true,
  };
  const { container } = render(MessageBubble, { message: first, progressMessages: [first, second] });
  expect(container.querySelectorAll('section')).toHaveLength(2);
  expect(container.querySelector('strong')?.textContent).toBe('Checked.');
  expect(container.textContent).toContain('2m 03s elapsed');
  expect(container.textContent).toContain('report.txt');
  expect(container.querySelector('button[title="Play voice"]')).not.toBeNull();
  expect(container.textContent).not.toContain('Status unknown');
});

test('system messages render as a platform notice, not as anyone’s bubble', () => {
  const { container, getByTestId } = render(MessageBubble, {
    message: {
      id: 'sys',
      role: 'system',
      author_name: 'The house',
      content:
        'One will run on GPT-6 Astra in this conversation from their next turn (was GPT-6.1 Sol). Changed by Dan.',
      created_at: '2026-10-08T14:05:00Z',
    },
  });
  const notice = getByTestId('system-notice');
  expect(notice).toHaveTextContent('The house');
  expect(notice).toHaveTextContent('One will run on GPT-6 Astra in this conversation from their next turn');
  expect(notice.querySelector('time')).toHaveAttribute('datetime', '2026-10-08T14:05:00Z');
  expect(container.querySelector('[data-testid="message-group"]')).toBeNull();
  expect(container.querySelector('.justify-end')).toBeNull();
});
