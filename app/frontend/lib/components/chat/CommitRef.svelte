<script>
  import { page } from '@inertiajs/svelte';
  import { CheckCircle, RocketLaunch, XCircle } from 'phosphor-svelte';
  import { commitStatus, setCommitStatusAccount, watchCommitStatus } from '$lib/commit-status.svelte.js';
  import { STATUS_LABELS, commitRefKey, commitRefLookupable } from '$lib/commit-refs.js';

  // token comes from commitRefExtension; live is false while a message is
  // still streaming, so growing prefixes of a sha are not looked up.
  let { token, theme = {}, live = true } = $props();

  // Only references some repository of this reader's could answer are asked
  // about: the house's own for site admins, and the account's repositories
  // with commit badges on (the shared commit_badges prop).
  const accountId = $derived($page.props.account?.id ?? null);
  const enabled = $derived(live && accountId !== null && commitRefLookupable(token, $page.props.commit_badges));
  const key = $derived(commitRefKey(token));
  const status = $derived(enabled ? commitStatus(key) : null);

  // Watching keeps the badge current while it is on screen (see the store).
  $effect(() => {
    if (!enabled) return;
    setCommitStatusAccount(accountId);
    return watchCommitStatus(key);
  });
</script>

<!-- No whitespace between tags below: it would render as a space before punctuation. -->
{#snippet icon()}{#if status === 'deployed'}<RocketLaunch
      size="1em"
      weight="fill"
      class="text-green-600 dark:text-green-400" />{:else if status === 'merged' || status === 'on_default'}<CheckCircle
      size="1em"
      weight="fill"
      class="text-green-600 dark:text-green-400" />{:else}<XCircle
      size="1em"
      weight="fill"
      class="text-red-500 dark:text-red-400" />{/if}{/snippet}
{#if token.form === 'code'}<code data-streamdown-codespan class={theme.codespan?.base}>{token.sha}</code
  >{:else if token.form === 'url'}<a
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
