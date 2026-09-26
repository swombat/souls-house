<script>
  import { chatViewport } from '$lib/chat-viewport';
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

<!-- Match --background in application.css using browser-chrome-safe sRGB colours. -->
<ModeWatcher themeColors={{ light: '#ffffff', dark: '#0a0a0a' }} />
<div
  use:chatViewport={!showFooter}
  class:chat-viewport={!showFooter}
  class="flex flex-col bg-bg {showFooter ? 'min-h-dvh' : 'overflow-hidden'}">
  <div class="shrink-0"><Navbar /></div>
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
