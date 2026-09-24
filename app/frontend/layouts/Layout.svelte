<script>
  import { page } from '@inertiajs/svelte';
  import { Toaster } from '$lib/components/shadcn/sonner/index.js';
  import { toast } from 'svelte-sonner';
  import Navbar from '$lib/components/navigation/navbar.svelte'; // Adjust the path as necessary
  import Footer from '$lib/components/navigation/Footer.svelte';
  import { ModeWatcher, setMode, resetMode, mode } from 'mode-watcher';

  let { children } = $props();
  let themeInitialized = false;
  const showFooter = $derived(!$page.component?.startsWith('chats/'));

  $effect(() => {
    let flash = $page.props?.flash || {};

    flash.notice && toast.success(flash.notice);
    flash.alert && toast.error(flash.alert);
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

<ModeWatcher />
<div class="flex flex-col bg-bg {showFooter ? 'min-h-dvh' : 'h-dvh overflow-hidden'}">
  <div class="shrink-0"><Navbar /></div>
  <main class={showFooter ? 'flex-1' : 'flex min-h-0 flex-1 flex-col'}>{@render children?.()}</main>
  {#if showFooter}
    <Footer />
  {/if}
  <Toaster />
</div>
