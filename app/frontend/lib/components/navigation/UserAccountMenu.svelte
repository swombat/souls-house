<script>
  import { router } from '@inertiajs/svelte';
  import {
    UserCircle,
    SignOut,
    Password,
    Moon,
    Sun,
    Monitor,
    Palette,
    Gear,
    Check,
    Plus,
    Plugs,
    Key,
    CurrencyDollar,
    Chalkboard,
    Megaphone,
  } from 'phosphor-svelte';
  import * as DropdownMenu from '$lib/components/shadcn/dropdown-menu/index.js';
  import { buttonVariants } from '$lib/components/shadcn/button/index.js';
  import { cn } from '$lib/utils.js';
  import {
    editUserPath,
    editUserPasswordPath,
    accountPath,
    accountAgentApiKeysPath,
    accountApiKeysPath,
    accountCostsPath,
    accountNoticesPath,
    newAccountPath,
    accountWhiteboardsPath,
  } from '@/routes';
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
</script>

<DropdownMenu.Root>
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
  <DropdownMenu.Content class="w-56" align="end">
    <DropdownMenu.Group>
      {#if accounts.length > 1}
        <DropdownMenu.Sub>
          <DropdownMenu.SubTrigger>
            <div class="flex flex-col items-start">
              <div class="text-xs font-normal text-muted-foreground">Account</div>
              <div class="text-sm font-semibold truncate">
                {currentAccount?.name}
              </div>
            </div>
            <span class="ml-auto"><ReplyAttentionBadge count={replyAttention.total} /></span>
          </DropdownMenu.SubTrigger>
          <DropdownMenu.SubContent>
            {#each accounts as account}
              <DropdownMenu.Item
                onclick={() => router.visit(`/accounts/${account.id}/chats`)}
                class={account.id === currentAccount?.id ? 'bg-accent' : ''}>
                <Check class="mr-2 size-4 {account.id === currentAccount?.id ? 'opacity-100' : 'opacity-0'}" />
                <span class="truncate">{account.name}</span>
                <span class="ml-auto pl-2"><ReplyAttentionBadge count={replyAttention.accounts?.[account.id]} /></span>
              </DropdownMenu.Item>
            {/each}
            <DropdownMenu.Separator />
            <DropdownMenu.Item disabled={!allowAccountCreation} onclick={() => router.visit(newAccountPath())}>
              <Plus class="mr-2 size-4" />
              <span>New Account</span>
            </DropdownMenu.Item>
          </DropdownMenu.SubContent>
        </DropdownMenu.Sub>
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
      <DropdownMenu.Item onclick={() => router.visit(editUserPath())}>
        <UserCircle class="mr-2 size-4" />
        <span>User Settings</span>
      </DropdownMenu.Item>
      {#if currentAccount?.id}
        <DropdownMenu.Item onclick={() => router.visit(`/accounts/${currentAccount.id}/integrations`)}>
          <Plugs class="mr-2 size-4" />
          <span>Integrations</span>
        </DropdownMenu.Item>
      {/if}
      {#if currentAccount?.id}
        {#if hasWhiteboards}
          <DropdownMenu.Item onclick={() => router.visit(accountWhiteboardsPath(currentAccount.id))}>
            <Chalkboard class="mr-2 size-4" />
            <span>Whiteboards</span>
          </DropdownMenu.Item>
        {/if}
        <DropdownMenu.Item onclick={() => router.visit(accountCostsPath(currentAccount.id))}>
          <CurrencyDollar class="mr-2 size-4" />
          <span>Costs</span>
        </DropdownMenu.Item>
        <DropdownMenu.Item onclick={() => router.visit(accountNoticesPath(currentAccount.id))}>
          <Megaphone class="mr-2 size-4" />
          <span>Resident Notices</span>
        </DropdownMenu.Item>
        <DropdownMenu.Item onclick={() => router.visit(accountAgentApiKeysPath(currentAccount.id))}>
          <Key class="mr-2 size-4" />
          <span>Resident API Keys</span>
        </DropdownMenu.Item>
        <DropdownMenu.Item onclick={() => router.visit(accountApiKeysPath(currentAccount.id))}>
          <Plugs class="mr-2 size-4" />
          <span>External Access</span>
        </DropdownMenu.Item>
        <DropdownMenu.Item onclick={() => router.visit(accountPath(currentAccount.id))}>
          <Gear class="mr-2 size-4" />
          <span>Account Settings</span>
        </DropdownMenu.Item>
      {/if}
      <DropdownMenu.Item disabled={!allowAccountCreation} onclick={() => router.visit(newAccountPath())}>
        <Plus class="mr-2 size-4" />
        <span>New Account</span>
      </DropdownMenu.Item>
      <DropdownMenu.Item onclick={() => router.visit(editUserPasswordPath())}>
        <Password class="mr-2 size-4" />
        <span>Change Password</span>
      </DropdownMenu.Item>
      <DropdownMenu.Sub>
        <DropdownMenu.SubTrigger>
          <Palette class="mr-2 size-4" />
          <span>Theme</span>
        </DropdownMenu.SubTrigger>
        <DropdownMenu.SubContent>
          <DropdownMenu.Item onclick={() => onThemeChange('light')} class={currentTheme === 'light' ? 'bg-accent' : ''}>
            <Sun class="mr-2 size-4" />
            Light
          </DropdownMenu.Item>
          <DropdownMenu.Item onclick={() => onThemeChange('dark')} class={currentTheme === 'dark' ? 'bg-accent' : ''}>
            <Moon class="mr-2 size-4" />
            Dark
          </DropdownMenu.Item>
          <DropdownMenu.Item
            onclick={() => onThemeChange('system')}
            class={currentTheme === 'system' ? 'bg-accent' : ''}>
            <Monitor class="mr-2 size-4" />
            System
          </DropdownMenu.Item>
        </DropdownMenu.SubContent>
      </DropdownMenu.Sub>
      <DropdownMenu.Separator />
      <DropdownMenu.Item onclick={onLogout}>
        <SignOut class="mr-2 size-4" />
        <span>Log out</span>
      </DropdownMenu.Item>
    </DropdownMenu.Group>
  </DropdownMenu.Content>
</DropdownMenu.Root>
