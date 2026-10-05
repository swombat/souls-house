<script>
  import { page } from '@inertiajs/svelte';
  import { CheckCircle, RocketLaunch, XCircle } from 'phosphor-svelte';
  import { commitStatus, watchCommitStatus } from '$lib/commit-status.svelte.js';
  import { STATUS_LABELS } from '$lib/commit-refs.js';

  // token comes from commitRefExtension; live is false while a message is
  // still streaming, so growing prefixes of a sha are not looked up.
  let { token, theme = {}, live = true } = $props();

  const enabled = $derived(live && ($page.props.user?.site_admin ?? false));
  const status = $derived(enabled ? commitStatus(token.sha) : null);

  // Watching keeps the badge current while it is on screen (see the store).
  $effect(() => {
    if (enabled) return watchCommitStatus(token.sha);
  });
</script>

<!-- No whitespace between tags below: it would render as a space before punctuation. -->
{#snippet icon()}{#if status === 'deployed'}<RocketLaunch
      size="1em"
      weight="fill"
      class="text-green-600 dark:text-green-400" />{:else if status === 'merged'}<CheckCircle
      size="1em"
      weight="fill"
      class="text-green-600 dark:text-green-400" />{:else}<XCircle
      size="1em"
      weight="fill"
      class="text-red-500 dark:text-red-400" />{/if}{/snippet}
{#if token.form === 'code'}<code class={theme.codespan?.base}>{token.sha}</code>{:else if token.form === 'url'}<a
    class={theme.link?.base}
    href={token.href}
    target="_blank"
    rel="noopener noreferrer">{token.href}</a
  >{:else}{token.sha}{/if}{#if status}<span
    class="commit-status inline-flex align-[-0.15em] ml-0.5 select-none"
    data-commit-status={status}
    role="img"
    aria-label={STATUS_LABELS[status]}
    title={STATUS_LABELS[status]}>{@render icon()}</span
  >{/if}
