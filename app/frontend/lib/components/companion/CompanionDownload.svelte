<script>
  import { page } from '@inertiajs/svelte';
  import { AppleLogo, Check, Copy, LinuxLogo, Warning } from 'phosphor-svelte';
  import { buttonVariants } from '$lib/components/shadcn/button/index.js';
  import { copyText } from '$lib/clipboard';

  // The one Mac download control. The main button links a file only when Site
  // Admin holds the address of a signed, notarised build; until then it says
  // so and links nothing. An early, unsigned build may be offered beneath it,
  // only with its checksum and a notice of what macOS will do (eqRAMj JBVBOD).
  // Linux (no signing step) shows beside it on every OS once Site Admin holds
  // an address and sha256 for the versioned installer or manual tarballs
  // (Daniel, eQwVPJ). When the installer is configured, the copy-paste line
  // downloads it whole to a temp file before running it (never curl | sh),
  // with an inspect-first link and manual tarballs below. `early` false keeps
  // a compact placement: the Mac button, and a link to /companion#download.
  let { size = 'lg', early = true } = $props();

  const settings = $derived($page.props.site_settings ?? {});
  const url = $derived(settings.companion_mac_download_url || null);
  const earlyUrl = $derived(settings.companion_mac_early_download_url || null);
  const earlySha = $derived(settings.companion_mac_early_download_sha256 || null);
  const linuxInstaller = $derived(
    settings.companion_linux_installer_download_url && settings.companion_linux_installer_download_sha256
      ? {
          url: settings.companion_linux_installer_download_url,
          sha: settings.companion_linux_installer_download_sha256,
        }
      : null
  );
  const linuxInstallCommand = $derived(
    linuxInstaller && /^[0-9a-f]{64}$/i.test(linuxInstaller.sha)
      ? `f=$(mktemp) && (curl -fsSL --proto '=https' --tlsv1.2 -o "$f" '${linuxInstaller.url.replaceAll("'", "'\\''")}' && printf '%s  %s\\n' '${linuxInstaller.sha.toLowerCase()}' "$f" | sha256sum -c --quiet && sh "$f"; rc=$?; rm -f "$f"; exit "$rc")`
      : null
  );
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
  const linuxOffered = $derived(Boolean(linuxInstaller) || linux.length > 0);

  let copied = $state(false);
  let copyTimer = null;

  async function copyInstallCommand() {
    if (!linuxInstallCommand) return;
    if (await copyText(linuxInstallCommand)) {
      copied = true;
      if (copyTimer) clearTimeout(copyTimer);
      copyTimer = setTimeout(() => {
        copied = false;
      }, 2000);
    }
  }
</script>

<!-- Compact: no box of its own, so the Mac button and the Linux link sit in
     the caller's row, centred with its other buttons (Daniel, YMamQY). -->
<div class={early ? 'flex flex-col items-start gap-3' : 'contents'} data-testid="companion-download-group">
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
  {#if linuxOffered}
    {#if early}
      <div class="max-w-xl rounded-xl border p-4 text-left text-sm" data-testid="companion-linux">
        <p class="flex items-center gap-2 font-medium"><LinuxLogo size={16} weight="fill" /> Linux, early build</p>
        <p class="mt-1 text-muted-foreground">
          Runs as your own systemd user service, never as root, with the house mark in your tray to pause or resume it.
          {linuxInstaller ? 'Downloads the release installer to a temporary file, verifies checksums, and walks through setup.' : 'Pick your processor.'}
        </p>
        {#if linuxInstaller && linuxInstallCommand}
          <div class="mt-3 space-y-2" data-testid="companion-linux-installer">
            <div class="flex items-start gap-2 rounded-lg border bg-muted/50 p-2.5">
              <code
                class="min-w-0 flex-1 overflow-x-auto font-mono text-xs break-all"
                data-testid="companion-linux-command">{linuxInstallCommand}</code>
              <button
                type="button"
                onclick={copyInstallCommand}
                class="{buttonVariants({ variant: 'secondary', size: 'sm' })} shrink-0"
                data-testid="companion-linux-copy">
                {#if copied}
                  <Check size={14} /> Copied
                {:else}
                  <Copy size={14} /> Copy
                {/if}
              </button>
            </div>
            <p class="text-xs text-muted-foreground">
              <a
                href={linuxInstaller.url}
                target="_blank"
                rel="noopener noreferrer"
                class="underline underline-offset-4"
                data-testid="companion-linux-inspect">Inspect the installer first</a>
              · sha256 <code class="font-mono break-all" data-testid="companion-linux-installer-sha256">{linuxInstaller.sha}</code>
            </p>
          </div>
        {/if}
        {#if linux.length > 0}
          {#if linuxInstaller}
            <details class="mt-3 text-xs text-muted-foreground" data-testid="companion-linux-manual">
              <summary class="cursor-pointer font-medium text-foreground">Manual tarballs</summary>
              <div class="mt-2.5 space-y-3">
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
            </details>
          {:else}
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
          {/if}
        {/if}
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
