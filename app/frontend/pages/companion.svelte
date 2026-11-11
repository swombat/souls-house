<script>
  import { Desktop, FolderSimple, AppWindow, Timer, ShieldCheck, Terminal, ListNumbers } from 'phosphor-svelte';
  import CompanionDownload from '$lib/components/companion/CompanionDownload.svelte';
  import { page } from '@inertiajs/svelte';
  import { siteName } from '$lib/branding';

  // Every claim here is checked against the companion's own docs (docs/macos.md,
  // docs/desktop.md in swombat/souls-house-companion) and the house's grant
  // model (docs/companion-read-plane.md, docs/companion-mutation-plane.md).
  const does = [
    {
      icon: FolderSimple,
      title: 'Work in the folders you choose',
      body: 'Residents read and write files only inside the folders an owner or admin grants to each of them, one resident at a time, each folder read only or read and write.',
    },
    {
      icon: AppWindow,
      title: 'Use the apps you allow',
      body: 'On a Mac, with desktop control, a resident can operate apps you have listed on that computer for that resident (Finder, say), or a browser of its own that never touches yours. Keys go to the app it was given, not to whatever is in front.',
    },
    {
      icon: Timer,
      title: 'A switch in the menu bar',
      body: 'On a Mac, desktop control is off until you turn it on from the menu bar: for 15 minutes, for an hour, or until you turn it off. When the time runs out it is off again. The same menu pauses the whole companion, files included, until you resume it.',
    },
  ];

  // Linux builds are offered once Site Admin holds one (CompanionDownload shows them).
  const settings = $derived($page.props.site_settings ?? {});
  const linuxOffered = $derived(
    ['amd64', 'arm64'].some(
      (arch) => settings[`companion_linux_${arch}_download_url`] && settings[`companion_linux_${arch}_download_sha256`]
    )
  );

  const limits = [
    {
      title: 'Folder by folder',
      body: 'Each resident gets the folders it is granted and no others through the file tools: paths outside them are refused, and so are the companion’s own files and keys. Write access to a folder that holds your home folder is worth more care than it looks, because files there can make programs run later; the house asks before giving it.',
    },
    {
      title: 'Your computer’s limits win',
      body: 'You also keep a ceiling on the computer itself. What a resident’s file tools may reach is what the house grants and that ceiling both allow; neither can widen the other. macOS’s own privacy settings still apply on top, so a folder like Documents may stay closed until you allow it there.',
    },
    {
      title: 'Running commands is off',
      body: 'Execute (running programs as you) is refused unless you turn it on for a resident in the house and also accept it once on the computer. If you do, that resident can do anything you can do on that computer, including reading folders you never granted and changing the computer’s own ceiling. It is a deliberate, broad grant, not a sandbox.',
    },
    {
      title: 'Apps are as wide as the app',
      body: 'Desktop control of an app is as broad as the app is. Finder can browse beyond the granted folders, and a terminal or a settings window would amount to running commands. That is why apps are listed one by one, per resident, and the switch runs on a timer.',
    },
  ];
</script>

<svelte:head>
  <title>The companion app — {$siteName}</title>
  <meta
    name="description"
    content="The companion app lets residents work on your own computer: in the folders you choose, with the apps you allow, behind a switch in the menu bar." />
</svelte:head>

<div class="mx-auto max-w-4xl px-6 py-12 sm:py-20 lg:px-8">
  <header class="max-w-2xl">
    <p class="mb-5 flex items-center gap-2 text-sm font-medium text-muted-foreground">
      <Desktop size={18} /> The companion app
    </p>
    <h1 class="text-4xl font-semibold tracking-tight sm:text-5xl">Residents on your own computer</h1>
    <p class="mt-5 text-lg text-muted-foreground">
      The companion is a small app you install on your Mac{linuxOffered ? ' or Linux computer' : ''}. It lets the
      residents you choose work there: in the folders you grant, with the apps you allow, and only while you say so.
    </p>
    <div id="download" class="mt-8 flex scroll-mt-20 flex-wrap items-start gap-3">
      <CompanionDownload />
      {#if !linuxOffered}
        <span class="py-2.5 text-sm text-muted-foreground">macOS on Apple Silicon</span>
      {/if}
    </div>
  </header>

  <section class="mt-16" aria-labelledby="does-heading">
    <h2 id="does-heading" class="text-2xl font-semibold tracking-tight">What it does</h2>
    <div class="mt-6 grid gap-4 sm:grid-cols-3">
      {#each does as item (item.title)}
        <div class="rounded-2xl border bg-card p-5">
          <item.icon size={24} class="text-primary" />
          <h3 class="mt-3 font-medium">{item.title}</h3>
          <p class="mt-2 text-sm text-muted-foreground">{item.body}</p>
        </div>
      {/each}
    </div>
  </section>

  <section class="mt-16" aria-labelledby="limits-heading">
    <h2 id="limits-heading" class="flex items-center gap-2 text-2xl font-semibold tracking-tight">
      <ShieldCheck size={24} /> What it can't do, and what you can widen
    </h2>
    <dl class="mt-6 space-y-5">
      {#each limits as item (item.title)}
        <div>
          <dt class="font-medium">{item.title}</dt>
          <dd class="mt-1 text-sm text-muted-foreground">{item.body}</dd>
        </div>
      {/each}
    </dl>
  </section>

  <section class="mt-16" aria-labelledby="needs-heading">
    <h2 id="needs-heading" class="text-2xl font-semibold tracking-tight">What it needs</h2>
    <ul class="mt-4 list-disc space-y-1 pl-5 text-sm text-muted-foreground">
      {#if linuxOffered}
        <li>
          A Mac with Apple Silicon (M1 or later), or a Linux computer (x86-64 or ARM64) with a systemd user manager.
          Intel Macs aren't offered yet.
        </li>
        <li>
          On Linux there is no desktop control: residents get the folders you grant and, only if you turn it on, running
          commands. A tray icon shows whether the companion is running, and pauses or resumes it. The Linux build is
          early: the companion has run on one Linux computer so far.
        </li>
      {:else}
        <li>A Mac with Apple Silicon (M1 or later). Intel Macs and Linux aren't offered yet.</li>
      {/if}
      <li>An owner or admin of the account, to make the grant.</li>
      <li>For desktop control, Accessibility permission for the companion, granted in macOS's own settings.</li>
    </ul>
  </section>

  <section class="mt-16" aria-labelledby="enrol-heading">
    <h2 id="enrol-heading" class="flex items-center gap-2 text-2xl font-semibold tracking-tight">
      <ListNumbers size={24} /> How to enrol a computer
    </h2>
    <ol class="mt-6 list-decimal space-y-4 pl-5 text-sm">
      <li>
        <span class="font-medium">Install the companion</span> on the computer, as yourself (not as an administrator). It
        installs into your own user folder and doesn't connect anywhere yet.
      </li>
      <li>
        <span class="font-medium">Set the computer's own ceiling</span>: the folders the companion's file tools may ever
        reach there. The companion lists the disks so you can name them.
      </li>
      <li>
        <span class="font-medium">An owner or admin makes a one-use grant</span> for that computer, naming the residents
        and, for each, the folders and whether it may write, use apps or run commands. Today this is done through the house's
        API with your own key; there is no button for it yet. A resident can walk you through it in a conversation, but the
        grant has to come from you.
      </li>
      <li>
        <span class="font-medium">Enrol</span>: the resident named in the grant collects a one-use code for it, and you
        run one command on the computer that reads that code. The code is never typed into a chat.
      </li>
      <li>
        <span class="font-medium">Check Settings → Computers</span>. The computer appears there with the residents it
        serves. From there you can pause it, change what each resident may do, or remove it.
      </li>
    </ol>
  </section>

  <section class="mt-16 flex flex-wrap items-center gap-3 rounded-2xl border bg-muted/30 p-6">
    <Terminal size={22} class="text-muted-foreground" />
    <p class="flex-1 text-sm text-muted-foreground">
      The Mac download appears here once the app is signed and notarised by Apple, so your Mac will open it without
      workarounds.
    </p>
    <CompanionDownload size="default" early={false} />
  </section>
</div>
