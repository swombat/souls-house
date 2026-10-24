<script>
  import { router } from '@inertiajs/svelte';
  import { Check } from 'phosphor-svelte';
  import { accountChatsPath } from '@/routes';
  import ReplyAttentionBadge from './ReplyAttentionBadge.svelte';
  import ExpiredSubscriptionsBadge from './ExpiredSubscriptionsBadge.svelte';

  // Wraps the account name beside the logo. On a computer, resting the mouse on
  // it shows the other accounts you belong to, no click needed. Touch keeps the
  // name as a plain link; switching there stays in the user account menu.
  let { currentAccount, accounts = [], replyAttention = {}, expiredSubscriptions = {}, children } = $props();

  const CLOSE_DELAY_MS = 200;
  let open = $state(false);
  let closeTimer = null;

  const switchable = $derived(accounts.length > 1);

  function cancelClose() {
    clearTimeout(closeTimer);
    closeTimer = null;
  }

  function show(event) {
    if (!switchable || event.pointerType !== 'mouse') return;
    cancelClose();
    open = true;
  }

  function hide(event) {
    if (event.pointerType !== 'mouse') return;
    cancelClose();
    closeTimer = setTimeout(() => (open = false), CLOSE_DELAY_MS);
  }

  function closeNow() {
    cancelClose();
    open = false;
  }

  // Plain anchors so middle-click and cmd-click still open a new tab; an ordinary
  // click goes through the router like the rest of the navbar.
  function visit(event, href) {
    closeNow();
    if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    event.preventDefault();
    router.visit(href);
  }

  $effect(() => () => clearTimeout(closeTimer));
</script>

<svelte:window onkeydown={(event) => event.key === 'Escape' && closeNow()} />

<div
  class="relative min-w-0"
  role="presentation"
  data-testid="nav-account-switcher"
  onpointerenter={show}
  onpointerleave={hide}>
  {@render children()}
  {#if open && switchable}
    <!-- pt-2 bridges the gap under the name so the pointer can travel into the list without it closing. -->
    <div class="absolute left-0 top-full z-50 hidden pt-2 md:block" data-testid="nav-account-switcher-panel">
      <div class="w-64 max-w-[80vw] rounded-md border bg-popover p-1 text-popover-foreground shadow-md">
        <div class="px-2 py-1.5 text-xs text-muted-foreground">Switch account</div>
        {#each accounts as account (account.id)}
          {@const current = account.id === currentAccount?.id}
          <a
            href={accountChatsPath(account.id)}
            onclick={(event) => visit(event, accountChatsPath(account.id))}
            aria-current={current ? 'page' : undefined}
            class="flex items-center gap-2 rounded-sm px-2 py-1.5 text-sm outline-none hover:bg-accent hover:text-accent-foreground focus-visible:bg-accent {current
              ? 'font-semibold'
              : ''}">
            <Check class="size-4 shrink-0 {current ? 'opacity-100' : 'opacity-0'}" />
            <span class="min-w-0 truncate">{account.name}</span>
            <span class="ml-auto flex shrink-0 gap-1">
              <ReplyAttentionBadge count={replyAttention.accounts?.[account.id]} />
              <ExpiredSubscriptionsBadge count={expiredSubscriptions.accounts?.[account.id]} />
            </span>
          </a>
        {/each}
      </div>
    </div>
  {/if}
</div>
