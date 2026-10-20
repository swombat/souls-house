<script>
  import { inertia } from '@inertiajs/svelte';
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
          <!-- A plain anchor with the inertia action: the legacy Link component drops aria-current and onclick. -->
          <a
            href={accountChatsPath(account.id)}
            use:inertia
            onclick={closeNow}
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
