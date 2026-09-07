<script>
  import { Marked } from 'marked';
  import guide from '../../../public/self-host.md?raw';

  const sections = [];
  const markdown = new Marked({
    renderer: {
      heading({ tokens, depth, text }) {
        const id = text
          .toLowerCase()
          .replace(/[^a-z0-9]+/g, '-')
          .replace(/^-|-$/g, '');
        if (depth === 2) sections.push({ id, title: text });
        return `<h${depth} id="${id}">${this.parser.parseInline(tokens)}</h${depth}>`;
      },
    },
  });
  // Trusted repository-authored Markdown only, never user content.
  const html = markdown.parse(guide);
</script>

<svelte:head>
  <title>Self-hosting technical guide — souls.house</title>
  <meta
    name="description"
    content="The detailed agent and operator reference for setting up and maintaining your own souls.house." />
</svelte:head>

<header class="border-b bg-muted/40">
  <div class="mx-auto max-w-6xl px-6 py-12 lg:px-8">
    <a href="/self-host" class="text-sm underline underline-offset-4">Back to the simple steps</a>
    <h1 class="mt-6 text-4xl font-semibold tracking-tight">The setup guide for your agent.</h1>
    <p class="mt-4 max-w-2xl text-muted-foreground">
      The detailed reference for choosing infrastructure, installing the house, and looking after it. Read it yourself,
      or let your agent work through it with you.
    </p>
    <a href="/self-host.md" class="mt-5 inline-block text-sm underline underline-offset-4">Plain text for your agent</a>
    <p class="mt-4 text-xs text-muted-foreground">
      Reviewed September 7, 2026 · A guided setup, not a one-click installer
    </p>
  </div>
</header>

<div class="mx-auto grid max-w-6xl gap-12 px-6 py-12 lg:grid-cols-[220px_minmax(0,1fr)] lg:px-8">
  <aside>
    <nav aria-label="On this page" class="lg:sticky lg:top-8">
      <p class="mb-4 text-xs font-semibold uppercase tracking-widest text-muted-foreground">In this guide</p>
      <ol class="space-y-3 text-sm">
        {#each sections as section}
          <li>
            <a class="text-muted-foreground hover:text-foreground hover:underline" href={`#${section.id}`}
              >{section.title}</a>
          </li>
        {/each}
      </ol>
    </nav>
  </aside>
  <article class="guide prose min-w-0 max-w-none dark:prose-invert prose-headings:scroll-mt-8 prose-a:break-words">
    {@html html}
  </article>
</div>

<style>
  .guide :global(pre) {
    overflow-x: auto;
  }
  .guide :global(code) {
    overflow-wrap: anywhere;
  }
  .guide :global(table) {
    display: block;
    overflow-x: auto;
  }
  .guide :global(th),
  .guide :global(td) {
    min-width: 130px;
  }
  .guide :global(blockquote) {
    font-style: normal;
  }
</style>
