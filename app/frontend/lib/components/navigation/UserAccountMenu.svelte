<script>
  import { router } from '@inertiajs/svelte';
  import { tick } from 'svelte';
  import {
    UserCircle,
    SignOut,
    Password,
    Moon,
    Sun,
    Monitor,
    ArrowLeft,
    CaretRight,
    Gear,
    Check,
    Plus,
    Chalkboard,
  } from 'phosphor-svelte';
  import * as DropdownMenu from '$lib/components/shadcn/dropdown-menu/index.js';
  import { buttonVariants } from '$lib/components/shadcn/button/index.js';
  import { cn } from '$lib/utils.js';
  import { editUserPath, editUserPasswordPath, accountPath, newAccountPath, accountWhiteboardsPath } from '@/routes';
  import Avatar from '$lib/components/Avatar.svelte';
  import ReplyAttentionBadge from './ReplyAttentionBadge.svelte';

  let {
    currentUser,
    currentAccount = null,
    accounts = [],
    replyAttention = {},
    hasWhiteboards = false,
    allowAccountCreation = true,
    currentTheme = 'system',
    onThemeChange = () => {},
    onLogout = () => {},
  } = $props();

  let panel = $state('main');
  let content = $state(null);

  async function showPanel(event, nextPanel) {
    event.preventDefault();
    panel = nextPanel;
    await tick();
    content?.querySelector('[role="menuitem"]')?.focus();
  }
</script>

<DropdownMenu.Root
  onOpenChange={(open) => {
    if (!open) panel = 'main';
  }}>
  <DropdownMenu.Trigger
    aria-label="User account menu"
    class={cn(buttonVariants({ variant: 'outline' }), 'rounded-full pl-0.5 pr-0.5 md:pr-2.5 gap-1 h-9')}>
    <Avatar user={currentUser} size="small" class="!size-8" />
    {#if currentUser?.full_name}
      <span class="text-xs font-normal text-muted-foreground hidden md:inline">
        {currentUser?.full_name}
      </span>
    {:else}
      <span class="text-xs font-normal text-muted-foreground hidden md:inline"> Account </span>
    {/if}
    <ReplyAttentionBadge count={replyAttention.total} />
  </DropdownMenu.Trigger>
  <DropdownMenu.Content
    bind:ref={content}
    class="w-56 max-w-[calc(100vw-1rem)] max-h-[var(--bits-dropdown-menu-content-available-height)] overflow-y-auto"
    align="end">
    <DropdownMenu.Group>
      {#if panel === 'accounts'}
        <DropdownMenu.Item onSelect={(event) => showPanel(event, 'main')}>
          <ArrowLeft class="size-4" />
          <span>Back</span>
        </DropdownMenu.Item>
        <DropdownMenu.Separator />
        {#each accounts as account}
          <DropdownMenu.Item
            onclick={() => router.visit(`/accounts/${account.id}/chats`)}
            class={account.id === currentAccount?.id ? 'bg-accent' : ''}>
            <Check class="size-4 {account.id === currentAccount?.id ? 'opacity-100' : 'opacity-0'}" />
            <span class="min-w-0 truncate">{account.name}</span>
            <span class="ml-auto shrink-0"><ReplyAttentionBadge count={replyAttention.accounts?.[account.id]} /></span>
          </DropdownMenu.Item>
        {/each}
        <DropdownMenu.Separator />
        <DropdownMenu.Item disabled={!allowAccountCreation} onclick={() => router.visit(newAccountPath())}>
          <Plus class="size-4" />
          <span>New Account</span>
        </DropdownMenu.Item>
      {:else}
        {#if accounts.length > 1}
          <DropdownMenu.Item onSelect={(event) => showPanel(event, 'accounts')}>
            <div class="min-w-0 flex-1">
              <div class="text-xs font-normal text-muted-foreground">Account</div>
              <div class="text-sm font-semibold truncate">
                {currentAccount?.name}
              </div>
            </div>
            <span class="shrink-0"><ReplyAttentionBadge count={replyAttention.total} /></span>
            <CaretRight class="size-4" />
          </DropdownMenu.Item>
        {:else}
          <DropdownMenu.GroupHeading>
            <div class="text-xs font-normal text-muted-foreground">Account</div>
            <div class="text-sm font-semibold truncate">
              {currentAccount?.name}
            </div>
          </DropdownMenu.GroupHeading>
        {/if}
        <DropdownMenu.Separator />
        <DropdownMenu.GroupHeading>
          <div class="text-xs font-normal text-muted-foreground">Logged in as</div>
          <div class="text-sm font-semibold truncate">
            {currentUser.email_address}
          </div>
          <div class="text-sm font-semibold truncate text-red-500">
            {currentUser?.site_admin ? '(Site Admin)' : ''}
          </div>
        </DropdownMenu.GroupHeading>
        <DropdownMenu.Separator />
        {#if currentAccount?.id}
          <DropdownMenu.Item onclick={() => router.visit(accountPath(currentAccount.id))}>
            <Gear class="mr-2 size-4" />
            <span>Account Settings</span>
          </DropdownMenu.Item>
          {#if hasWhiteboards}
            <DropdownMenu.Item onclick={() => router.visit(accountWhiteboardsPath(currentAccount.id))}>
              <Chalkboard class="mr-2 size-4" />
              <span>Whiteboards</span>
            </DropdownMenu.Item>
          {/if}
        {/if}
        {#if accounts.length <= 1}
          <DropdownMenu.Item disabled={!allowAccountCreation} onclick={() => router.visit(newAccountPath())}>
            <Plus class="mr-2 size-4" />
            <span>New Account</span>
          </DropdownMenu.Item>
        {/if}
        <DropdownMenu.Separator />
        <DropdownMenu.Item onclick={() => router.visit(editUserPath())}>
          <UserCircle class="mr-2 size-4" />
          <span>User Settings</span>
        </DropdownMenu.Item>
        <DropdownMenu.Item onclick={() => router.visit(editUserPasswordPath())}>
          <Password class="mr-2 size-4" />
          <span>Change Password</span>
        </DropdownMenu.Item>
        <DropdownMenu.Separator />
        <DropdownMenu.GroupHeading>Theme</DropdownMenu.GroupHeading>
        <div class="flex">
          {#each [{ value: 'light', label: 'Light', icon: Sun }, { value: 'dark', label: 'Dark', icon: Moon }, { value: 'system', label: 'System', icon: Monitor }] as theme}
            <DropdownMenu.Item
              onclick={() => onThemeChange(theme.value)}
              aria-label={`${theme.label} theme${currentTheme === theme.value ? ' (selected)' : ''}`}
              class={cn('flex-1 flex-col gap-1 px-1 text-xs', currentTheme === theme.value && 'bg-accent')}>
              <theme.icon class="size-4" />
              {theme.label}
            </DropdownMenu.Item>
          {/each}
        </div>
        <DropdownMenu.Separator />
        <DropdownMenu.Item onclick={onLogout}>
          <SignOut class="mr-2 size-4" />
          <span>Log out</span>
        </DropdownMenu.Item>
      {/if}
    </DropdownMenu.Group>
  </DropdownMenu.Content>
</DropdownMenu.Root>
