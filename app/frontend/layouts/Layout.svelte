<script>
  import { chatViewport } from '$lib/chat-viewport';
  import { page } from '@inertiajs/svelte';
  import { Toaster } from '$lib/components/shadcn/sonner/index.js';
  import { showFlashToasts } from '$lib/flash-toasts.js';
  import Navbar from '$lib/components/navigation/navbar.svelte'; // Adjust the path as necessary
  import Footer from '$lib/components/navigation/Footer.svelte';
  import DeployAlarmBanner from '$lib/components/admin/DeployAlarmBanner.svelte';
  import { ModeWatcher, setMode, resetMode, mode } from 'mode-watcher';
  import { applyPersonalTint, applyAccountColour, browserChromeColours } from '$lib/theme';

  let { children } = $props();
  let themeInitialized = false;
  const showFooter = $derived(!$page.component?.startsWith('chats/'));
  // Every Admin:: page is for site admins only (the server says which: notices
  // renders notices/index); say so in the house's admin red.
  const adminPage = $derived(!!$page.props?.site_admin_page);
  const themeHue = $derived($page.props?.user?.theme_hue ?? null);
  const accountColour = $derived($page.props?.account?.logo_colour ?? null);
  const chromeColours = $derived(browserChromeColours(themeHue));

  // The server renders these on <html> for first paint; keep them current across
  // Inertia navigations (switching account, saving a new tint).
  $effect(() => {
    applyPersonalTint(document.documentElement, themeHue);
  });
  $effect(() => {
    applyAccountColour(document.documentElement, accountColour);
  });

  $effect(() => {
    showFlashToasts($page.props?.flash);
  });

  // Apply user's theme preference on initial load only
  $effect(() => {
    if (!themeInitialized) {
      const userTheme = $page.props?.user?.preferences?.theme || $page.props?.theme_preference;
      if (userTheme && userTheme !== 'system') {
        setMode(userTheme);
      } else if (userTheme === 'system') {
        resetMode();
      }
      themeInitialized = true;
    }
  });
</script>

<!-- Match --background in application.css (including the personal tint) in browser-chrome-safe sRGB. -->
<ModeWatcher themeColors={chromeColours} />
<div
  use:chatViewport={!showFooter}
  class:chat-viewport={!showFooter}
  class="flex flex-col bg-background {showFooter ? 'min-h-dvh' : 'overflow-hidden'}">
  <div class="shrink-0"><Navbar /></div>
  {#if $page.props?.deploy_alarm}
    <div class="shrink-0"><DeployAlarmBanner alarm={$page.props.deploy_alarm} /></div>
  {/if}
  {#if adminPage}
    <div
      class="shrink-0 border-b border-red-200 bg-red-50/70 px-4 py-1.5 text-center text-xs font-medium text-red-600 dark:border-red-900/60 dark:bg-red-950/30 dark:text-red-400"
      data-admin-only>
      Site admin page: only site admins can see this.
    </div>
  {/if}
  <main class={showFooter ? 'flex-1' : 'flex min-h-0 flex-1 flex-col'}>{@render children?.()}</main>
  {#if showFooter}
    <Footer />
  {/if}
  <Toaster />
</div>

<style>
  .chat-viewport {
    position: fixed;
    inset-inline: 0;
    top: var(--chat-viewport-top, 0px);
    height: var(--chat-viewport-height, 100dvh);
  }
</style>
