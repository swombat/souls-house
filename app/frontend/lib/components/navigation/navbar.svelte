<script>
  // grab page props from inertia
  import { page, Link, router } from '@inertiajs/svelte';
  import Logo from '$lib/components/misc/SiteLogo.svelte';
  import { UserCircle, Moon, Sun, MagnifyingGlass } from 'phosphor-svelte';
  import * as DropdownMenu from '$lib/components/shadcn/dropdown-menu/index.js';
  import { Button, buttonVariants } from '$lib/components/shadcn/button/index.js';
  import { cn } from '$lib/utils.js';
  import { loginPath, signupPath, logoutPath, searchAccountChatsPath, accountAgentsPath } from '@/routes';
  import { setMode, resetMode } from 'mode-watcher';
  import MobileNavMenu from '$lib/components/navigation/MobileNavMenu.svelte';
  import SiteAdminMenu from '$lib/components/navigation/SiteAdminMenu.svelte';
  import UserAccountMenu from '$lib/components/navigation/UserAccountMenu.svelte';
  import * as logging from '$lib/logging';
  import { DEFAULT_SITE_NAME } from '$lib/branding';

  function handleLogout(event) {
    event.preventDefault();
    router.delete(logoutPath());
  }

  const currentUser = $derived($page.props?.user);
  const currentAccount = $derived($page.props?.account);
  const accounts = $derived($page.props?.accounts || []);
  const accountHasWhiteboards = $derived($page.props?.account_has_whiteboards || false);
  const siteSettings = $derived($page.props?.site_settings);

  const links = $derived([
    {
      href: currentAccount?.id ? `/accounts/${currentAccount.id}/chats` : '#',
      label: 'Chats',
      show: !!currentUser && siteSettings?.allow_chats,
    },
    {
      href: currentAccount?.id ? accountAgentsPath(currentAccount.id) : '#',
      label: 'Residents',
      show: !!currentUser && siteSettings?.allow_agents && !!currentAccount?.id,
    },
  ]);

  // Search
  let navSearchQuery = $state('');

  function handleNavSearch(event) {
    event.preventDefault();
    if (!navSearchQuery.trim() || !currentAccount?.id) return;
    router.get(searchAccountChatsPath(currentAccount.id), { q: navSearchQuery.trim() });
    navSearchQuery = '';
  }

  // Theme management
  const currentTheme = $derived(currentUser?.preferences?.theme || $page.props?.theme_preference || 'system');

  async function updateTheme(theme) {
    // Update UI immediately
    if (theme === 'system') {
      resetMode();
    } else {
      setMode(theme);
    }

    // Save to server for logged-in users using a regular fetch request
    // to avoid Inertia navigation
    if (currentUser) {
      try {
        const response = await fetch('/user', {
          method: 'PATCH',
          headers: {
            'Content-Type': 'application/json',
            'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]')?.content || '',
          },
          body: JSON.stringify({
            user: {
              preferences: { theme },
            },
          }),
        });

        if (!response.ok) {
          logging.error('Failed to save theme preference');
        }
      } catch (error) {
        logging.error('Error saving theme preference:', error);
      }
    }

    // currentTheme will update automatically via derived
  }
</script>

<nav>
  <div class="flex items-center justify-between p-4 px-4 md:px-10 border-b gap-2 md:gap-4">
    <div class="flex items-center gap-4 md:gap-8">
      <Link href="/" class="flex items-center gap-2">
        <Logo class="h-8 w-8 md:h-10 md:w-10" />
        <span class="hidden sm:inline">{siteSettings?.site_name || DEFAULT_SITE_NAME}</span>
      </Link>
      <div class="hidden md:flex items-center">
        <!-- Remount Inertia links when their account-scoped href changes so the click handler cannot retain the previous URL. -->
        {#each links as link (`${link.label}:${link.href}`)}
          {#if link.show}
            <Link
              href={link.href}
              class={cn(buttonVariants({ variant: 'ghost' }), 'rounded-full text-muted-foreground')}>{link.label}</Link>
          {/if}
        {/each}
      </div>
    </div>

    <div class="flex-grow"></div>

    {#if currentUser && siteSettings?.allow_chats && currentAccount?.id}
      <form onsubmit={handleNavSearch} class="hidden md:flex items-center">
        <div class="relative">
          <MagnifyingGlass size={16} class="absolute left-2.5 top-1/2 -translate-y-1/2 text-muted-foreground" />
          <input
            type="text"
            bind:value={navSearchQuery}
            placeholder="Search..."
            class="w-40 lg:w-56 pl-8 pr-3 py-1.5 text-sm border border-input rounded-md
                   bg-background focus:outline-none focus:ring-2 focus:ring-ring
                   focus:border-transparent placeholder:text-muted-foreground/50" />
        </div>
      </form>
    {/if}

    <!-- Theme toggle for guest users only -->
    {#if !currentUser}
      <DropdownMenu.Root>
        <DropdownMenu.Trigger class={buttonVariants({ variant: 'outline', size: 'icon' })}>
          <Sun class="h-[1.2rem] w-[1.2rem] rotate-0 scale-100 !transition-all dark:-rotate-90 dark:scale-0" />
          <Moon
            class="absolute h-[1.2rem] w-[1.2rem] rotate-90 scale-0 !transition-all dark:rotate-0 dark:scale-100 text-slate-100" />
          <span class="sr-only">Toggle theme</span>
        </DropdownMenu.Trigger>
        <DropdownMenu.Content align="end">
          <DropdownMenu.Item onclick={() => setMode('light')}>Light</DropdownMenu.Item>
          <DropdownMenu.Item onclick={() => setMode('dark')}>Dark</DropdownMenu.Item>
          <DropdownMenu.Item onclick={() => resetMode()}>System</DropdownMenu.Item>
        </DropdownMenu.Content>
      </DropdownMenu.Root>
    {/if}

    {#if currentUser}
      <MobileNavMenu {links} {siteSettings} {currentAccount} />

      {#if currentUser?.site_admin}
        <SiteAdminMenu />
      {/if}
      <UserAccountMenu
        {currentUser}
        {currentAccount}
        {accounts}
        hasWhiteboards={accountHasWhiteboards}
        {currentTheme}
        onThemeChange={updateTheme}
        onLogout={handleLogout} />
    {:else}
      <!-- Mobile -->
      <DropdownMenu.Root>
        <DropdownMenu.Trigger class={cn(buttonVariants({ variant: 'outline' }), 'rounded-full px-2.5 gap-1')}>
          <UserCircle />
          <span class="text-xs font-normal text-muted-foreground"> Not Logged In </span>
        </DropdownMenu.Trigger>
        <DropdownMenu.Content class="w-56" align="end">
          <DropdownMenu.Group>
            {#if siteSettings?.allow_signups}
              <DropdownMenu.Item class="font-medium" onclick={() => router.visit(signupPath())}
                >Sign up</DropdownMenu.Item>
            {/if}
            <DropdownMenu.Item onclick={() => router.visit(loginPath())}>Log in</DropdownMenu.Item>
          </DropdownMenu.Group>
          <div class="md:hidden">
            <DropdownMenu.Separator />
            <DropdownMenu.Group>
              {#each links as link (`${link.label}:${link.href}`)}
                {#if link.show}
                  <DropdownMenu.Item onclick={() => router.visit(link.href)}>{link.label}</DropdownMenu.Item>
                {/if}
              {/each}
            </DropdownMenu.Group>
          </div>
        </DropdownMenu.Content>
      </DropdownMenu.Root>
    {/if}
  </div>
</nav>
