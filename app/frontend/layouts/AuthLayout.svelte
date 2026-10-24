<script>
  import { page } from '@inertiajs/svelte';
  import { Toaster } from '$lib/components/shadcn/sonner/index.js';
  import { showFlashToasts } from '$lib/flash-toasts.js';
  import Navbar from '$lib/components/navigation/navbar.svelte'; // Adjust the path as necessary

  let { children } = $props();

  $effect(() => {
    showFlashToasts($page.props?.flash);
  });
</script>

<div class="bg-bg">
  <main>{@render children?.()}</main>
  <Toaster />
</div>
