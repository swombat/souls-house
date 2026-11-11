<script>
  import { page } from '@inertiajs/svelte';
  import { AppleLogo, LinuxLogo, Warning } from 'phosphor-svelte';
  import { buttonVariants } from '$lib/components/shadcn/button/index.js';

  // The one Mac download control. The main button links a file only when Site
  // Admin holds the address of a signed, notarised build; until then it says
  // so and links nothing. An early, unsigned build may be offered beneath it,
  // only with its checksum and a notice of what macOS will do (eqRAMj JBVBOD).
  // Linux tarballs (no signing step) show beside it on every OS, each with its
  // checksum, once Site Admin holds an address and sha256 for them (Daniel,
  // eQwVPJ). `early` false keeps a compact placement: the Mac button, and a
  // link to the companion page's downloads instead of the Linux checksums.
  let { size = 'lg', early = true } = $props();

  const settings = $derived($page.props.site_settings ?? {});
  const url = $derived(settings.companion_mac_download_url || null);
  const earlyUrl = $derived(settings.companion_mac_early_download_url || null);
  const earlySha = $derived(settings.companion_mac_early_download_sha256 || null);
  const linux = $derived(
    [
      { key: 'amd64', label: 'Linux x86-64' },
      { key: 'arm64', label: 'Linux ARM64' },
    ]
      .map((item) => ({
        ...item,
        url: settings[`companion_linux_${item.key}_download_url`] || null,
        sha: settings[`companion_linux_${item.key}_download_sha256`] || null,
      }))
      .filter((item) => item.url && item.sha)
  );
</script>

<div class="flex flex-col items-start gap-3">
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
    {#if early && earlyUrl && earlySha}
      <div
        class="max-w-xl rounded-xl border border-amber-300 bg-amber-50 p-4 text-left text-sm dark:border-amber-800 dark:bg-amber-950/40"
        data-testid="companion-early">
        <p class="flex items-center gap-2 font-medium"><Warning size={16} /> Want it now? An early build</p>
        <ul class="mt-2 list-disc space-y-1 pl-5 text-muted-foreground">
          <li>
            It isn't signed or notarised by Apple yet, so macOS won't open it the first time. Open System Settings →
            Privacy &amp; Security: it shows that the companion "was blocked to protect your Mac". Choose Open Anyway
            and confirm. You do this once for each part you open.
          </li>
          <li>Until the signed build ships, each update asks for the Accessibility permission again.</li>
          <li>The signed, notarised build replaces it once Apple has approved it.</li>
        </ul>
        <a
          href={earlyUrl}
          class="{buttonVariants({ variant: 'secondary', size: 'sm' })} mt-3"
          data-testid="companion-download-early">
          Download it early (unsigned)
        </a>
        <p class="mt-2 text-xs break-all text-muted-foreground">
          sha256 <code class="font-mono" data-testid="companion-early-sha256">{earlySha}</code>
        </p>
      </div>
    {/if}
  {/if}
  {#if linux.length > 0}
    {#if early}
      <div class="max-w-xl rounded-xl border p-4 text-left text-sm" data-testid="companion-linux">
        <p class="flex items-center gap-2 font-medium"><LinuxLogo size={16} weight="fill" /> Linux, early build</p>
        <p class="mt-1 text-muted-foreground">
          A command-line companion that runs as your own systemd user service, no root. Pick your processor.
        </p>
        <div class="mt-3 space-y-3">
          {#each linux as item (item.key)}
            <div>
              <a
                href={item.url}
                class={buttonVariants({ variant: 'secondary', size: 'sm' })}
                data-testid="companion-download-linux-{item.key}">
                <LinuxLogo size={16} weight="fill" />
                {item.label}
              </a>
              <p class="mt-1 text-xs break-all text-muted-foreground">
                sha256 <code class="font-mono" data-testid="companion-linux-{item.key}-sha256">{item.sha}</code>
              </p>
            </div>
          {/each}
        </div>
      </div>
    {:else}
      <a
        href="/companion#download"
        class="inline-flex items-center gap-1.5 text-sm text-muted-foreground underline-offset-4 hover:underline"
        data-testid="companion-linux-link">
        <LinuxLogo size={14} weight="fill" /> Linux download
      </a>
    {/if}
  {/if}
</div>
