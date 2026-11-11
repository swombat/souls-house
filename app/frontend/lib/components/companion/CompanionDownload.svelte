<script>
  import { page } from '@inertiajs/svelte';
  import { AppleLogo } from 'phosphor-svelte';
  import { buttonVariants } from '$lib/components/shadcn/button/index.js';

  // The one Mac download control. It links a file only when Site Admin holds
  // the address of a signed, notarised build; otherwise it says so and links
  // nothing, so nobody is offered a file their Mac will refuse to open.
  let { size = 'lg' } = $props();

  const url = $derived($page.props.site_settings?.companion_mac_download_url || null);
</script>

{#if url}
  <a href={url} class={buttonVariants({ variant: 'default', size })} data-testid="companion-download">
    <AppleLogo size={18} weight="fill" /> Download for Mac
  </a>
{:else}
  <span
    class="{buttonVariants({ variant: 'outline', size })} pointer-events-none opacity-70"
    aria-disabled="true"
    data-testid="companion-download-soon">
    <AppleLogo size={18} weight="fill" /> Mac download coming soon
  </span>
{/if}
