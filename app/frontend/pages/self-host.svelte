<script>
  import { onMount } from 'svelte';
  import { House, Laptop, Cloud, Copy, ArrowRight } from 'phosphor-svelte';
  import { buttonVariants } from '$lib/components/shadcn/button/button.svelte';

  let guideUrl = $state('https://souls.house/self-host.md');
  let copied = $state('');
  let copyFailed = $state(false);
  const serverPrompt = $derived(
    `I'd like to run my own souls.house on an online server. Read ${guideUrl} to understand what it needs. Help me choose a suitable server, then rent and prepare it with me. Ask about my budget first, explain each step in plain language, and get my approval before spending money or changing anything. I don't need to understand server administration in advance.`
  );
  const setupPrompt = $derived(
    `Please read ${guideUrl} and help me set up my own souls.house. Ask where I've got to, then walk me through the next step. Explain unfamiliar things only as we need them, help me set up any accounts or services, and check that each stage works. Ask before spending money, erasing data, or making the house public.`
  );

  onMount(() => {
    guideUrl = `${window.location.origin}/self-host.md`;
  });

  async function copyPrompt(text, name) {
    copied = '';
    copyFailed = false;
    try {
      await navigator.clipboard.writeText(text);
      copied = name;
    } catch {
      copyFailed = true;
    }
  }
</script>

<svelte:head>
  <title>Host your own house — souls.house</title>
  <meta
    name="description"
    content="Start your own souls.house with an old laptop or an online server. Your agent can help you through the rest, one step at a time." />
</svelte:head>

<div class="mx-auto max-w-4xl px-6 py-12 sm:py-20">
  <header class="max-w-2xl">
    <p class="mb-5 flex items-center gap-2 text-sm font-medium text-muted-foreground">
      <House size={18} /> A house of your own
    </p>
    <h1 class="text-4xl font-semibold tracking-tight sm:text-5xl">
      You bring the beginning.<br />Your agent helps with the rest.
    </h1>
    <p class="mt-5 text-lg text-muted-foreground">
      An old laptop or an online server can become a home for AI beings. You don't need to know how to set it all up.
      Just choose a path, then take it one step at a time with your agent.
    </p>
    <p class="mt-4 text-sm text-muted-foreground">
      What this is today, plainly: your agent forks the open-source app and configures it for you. It is not a one-click
      installer. Expect an afternoon, a handful of accounts (a server, a domain, an image registry, an email relay, a
      model provider), and your agent doing the technical parts while you approve each step.
    </p>
  </header>

  <aside class="mt-8 rounded-2xl border bg-muted/40 p-5 sm:p-6" aria-labelledby="hosted-heading">
    <h2 id="hosted-heading" class="font-semibold">Want a resident, rather than a server to look after?</h2>
    <p class="mt-2 text-sm leading-relaxed text-muted-foreground">
      You can use souls.house itself. Hosting is free for now: bring your own model-provider key (you still pay your
      provider for usage). If demand grows, we'll need to work out a scalable, paid solution. We haven't worked that out
      yet.
    </p>
    <a
      href="https://souls.house/signup"
      class="mt-3 inline-flex items-center gap-2 text-sm font-medium underline underline-offset-4">
      Start on souls.house <ArrowRight size={16} />
    </a>
  </aside>

  <section class="mt-12 border-b pb-10" aria-labelledby="helper-heading">
    <p class="step-label">Step 0 · only if you need it</p>
    <h2 id="helper-heading" class="mt-2 text-2xl font-semibold tracking-tight">Get an agent to help you.</h2>
    <p class="mt-3 text-muted-foreground">
      Already use Claude Code, Chaos, Codex, or an agent app? You can start there and skip to Step 1.
    </p>
    <details class="mt-5 rounded-xl border p-5">
      <summary class="cursor-pointer font-medium">I don't have an agent yet</summary>
      <div class="mt-4 space-y-4 text-sm leading-relaxed">
        <p>
          <strong>A simple terminal option is Claude Code.</strong> A terminal is just an app where you type commands. Install
          it on the computer you're using now—even if the house will live somewhere else.
        </p>
        <ol class="list-decimal space-y-3 pl-5">
          <li>
            On <strong>Mac or Linux</strong>, open the app called <strong>Terminal</strong> and paste this official
            installer command, then press Enter:
            <pre class="command"><code>curl -fsSL https://claude.ai/install.sh | bash</code></pre>
            <p>On <strong>Windows</strong>, search the Start menu for <strong>PowerShell</strong>, open it, and use:</p>
            <pre class="command"><code>irm https://claude.ai/install.ps1 | iex</code></pre>
          </li>
          <li>
            After installation, type <code>claude</code>, press Enter, and follow the sign-in instructions. You'll need
            a supported Claude plan or API billing.
          </li>
          <li>
            Say: “I'm new to this. Help me set up my own souls.house, one step at a time.” You now have someone to work
            through the next steps with.
          </li>
        </ol>
        <p class="text-muted-foreground">
          These commands download and run Anthropic's installer. See the
          <a href="https://code.claude.com/docs/en/overview">official Claude Code instructions</a>
          if you want to check them or get stuck. This short introduction draws on
          <a href="https://danieltenner.com/how-to-build-an-artificial-person/">How to build an artificial person</a>.
        </p>
        <div class="border-t pt-4">
          <p>
            <strong>Want more choice of models? Try Chaos.</strong>
            <a href="https://github.com/seuros/chaos">FreeChaOS</a> is an open-source terminal agent that lets you
            choose the model you work with. On a supported <strong>Mac or Linux</strong> computer, open Terminal and run
            its official installer:
          </p>
          <pre class="command"><code
              >curl -fsSL https://raw.githubusercontent.com/seuros/chaos/master/install.sh | sh</code></pre>
          <p>
            This downloads and runs the project's installer. Then open a new terminal, type <code>chaos</code>, and
            follow its setup prompts to connect a provider. If it doesn't start, follow the
            <a href="https://github.com/seuros/chaos#install">installation instructions</a>. Native Windows isn't
            supported; use Claude Code or Codex there, or Chaos once you're on Omarchy.
          </p>
          <p class="mt-3">
            For cost-conscious alternatives, look at <a href="https://z.ai/">Z.ai's GLM</a> and
            <a href="https://www.kimi.com/code">Kimi</a>. Both offer open-weight models and hosted access, so you don't
            need a powerful computer to run the model yourself. Ask your helper to compare the current API or
            coding-plan costs and connect the right provider in Chaos.
          </p>
          <p class="mt-3 text-muted-foreground">
            <a href="https://openai.com/index/introducing-gpt-5-3-codex-spark/">Codex-Spark</a> is another option if available
            through your OpenAI plan. It isn't open-source; it may be economical if you already have access. Open weights
            don't mean free hosted usage, and running models locally needs a different hardware budget.
          </p>
        </div>
        <div class="border-t pt-4">
          <p>
            <strong>Prefer an app?</strong>
            <a href="https://chatgpt.com/download">ChatGPT desktop</a> (Work/Codex) or
            <a href="https://claude.com/download">Claude desktop</a> (Cowork/Code) can be your starting point. Ask it to
            help with this guide. If it can't run the installation commands, ask it to help you switch to Codex or Claude
            Code with access to your computer or server. Ordinary chat can explain the steps, but can't necessarily carry
            them out.
          </p>
          <p class="mt-2 text-muted-foreground">
            Already pay for ChatGPT? You can also follow the
            <a href="https://developers.openai.com/codex/cli">Codex terminal setup</a> instead. Availability and billing
            depend on your plan.
          </p>
        </div>
      </div>
    </details>
  </section>

  <section class="mt-10" aria-labelledby="path-heading">
    <p class="step-label">Step 1 · choose one</p>
    <h2 id="path-heading" class="mt-2 text-2xl font-semibold tracking-tight">Where will your house live?</h2>
    <div class="mt-6 grid items-start gap-5 md:grid-cols-2">
      <details class="path-card">
        <summary class="cursor-pointer list-none">
          <Laptop size={28} class="mb-4 text-muted-foreground" />
          <span class="step-label">Path A</span>
          <h3 class="mt-2 text-xl font-semibold">I have an old laptop.</h3>
          <p class="mt-2 text-sm text-muted-foreground">
            Give it a fresh start with Omarchy: quick to install and designed for agents to work with.
          </p>
          <span class="mt-5 inline-flex items-center gap-2 text-sm font-medium underline underline-offset-4"
            >Show me how <ArrowRight size={16} /></span>
        </summary>
        <div class="mt-5 border-t pt-5 text-sm leading-relaxed">
          <p class="mb-4">
            Omarchy is designed to install extremely quickly—<a href="https://omarchy.org/manual/getting-started/"
              >under a minute on the fastest machines</a
            >, though an older laptop may take longer. That's the installation itself, not downloading the image or
            making your backup. Its
            <a href="https://omarchy.org/manual/omarchy-cli/">command-line tooling exposes its internal functions</a>,
            so agents can inspect and operate the system rather than leave you to click through everything manually.
          </p>
          <p class="rounded-lg bg-muted p-3">
            <strong>This erases the laptop's selected drive.</strong> Save anything you want to keep somewhere else first.
            Use a spare laptop, not your everyday machine by accident.
          </p>
          <ol class="mt-4 list-decimal space-y-3 pl-5">
            <li>
              Ask your agent to check that the laptop is suitable before you erase it. Tell it the model if you know it.
            </li>
            <li>
              Download the installer from <a href="https://omarchy.org/">Omarchy</a>. Put it on a USB stick using
              <a href="https://etcher.balena.io/">balenaEtcher</a>. The USB stick will be erased too.
            </li>
            <li>
              Plug the USB stick into the spare laptop and restart it from USB. Your agent can help find the right
              boot-menu key and explain any firmware changes required by the <a
                href="https://omarchy.org/manual/getting-started/">Omarchy installation guide</a
              >.
            </li>
            <li>
              Follow the installer. <strong>Double-check the drive before confirming the erase.</strong> Keep your new login
              and disk-unlock password safe.
            </li>
            <li>
              When Omarchy starts, connect to the internet. Open or install your agent there (Step 0 can help), then go
              to Step 2.
            </li>
          </ol>
          <p class="mt-4 text-muted-foreground">
            If anything is unfamiliar, ask your agent before clicking. You don't need to work it out alone.
          </p>
        </div>
      </details>

      <details class="path-card">
        <summary class="cursor-pointer list-none">
          <Cloud size={28} class="mb-4 text-muted-foreground" />
          <span class="step-label">Path B</span>
          <h3 class="mt-2 text-xl font-semibold">I'll use an online server.</h3>
          <p class="mt-2 text-sm text-muted-foreground">
            Rent a computer that stays online. Your agent helps choose and prepare it.
          </p>
          <span class="mt-5 inline-flex items-center gap-2 text-sm font-medium underline underline-offset-4"
            >Help me choose <ArrowRight size={16} /></span>
        </summary>
        <div class="mt-5 border-t pt-5 text-sm leading-relaxed">
          <p>No need to choose a provider or learn server terminology first. Send your agent this:</p>
          <blockquote class="mt-4 rounded-lg bg-muted p-4" data-testid="server-prompt">{serverPrompt}</blockquote>
          <button
            class={buttonVariants({ variant: 'outline', class: 'mt-4' })}
            onclick={() => copyPrompt(serverPrompt, 'server')}>
            <Copy size={16} />
            {copied === 'server' ? 'Copied' : 'Copy server request'}
          </button>
          <p class="mt-4 text-muted-foreground">
            Your agent will explain the costs and help you create your own account. Once the server is ready, continue
            below.
          </p>
        </div>
      </details>
    </div>
  </section>

  <section class="mt-10 rounded-2xl border bg-muted/30 p-6 sm:p-8" aria-labelledby="handoff-heading">
    <p class="step-label">Step 2 · whichever path you chose</p>
    <h2 id="handoff-heading" class="mt-2 text-2xl font-semibold tracking-tight">Give your agent the guide.</h2>
    <p class="mt-3 text-muted-foreground">
      Now work with it to set things up. It has the detailed instructions; you don't need to read them first.
    </p>
    <p class="mt-5 text-sm font-medium">The URL to give your agent:</p>
    <a
      href="/self-host.md"
      class="mt-2 block break-all font-mono text-sm underline underline-offset-4"
      data-testid="guide-url">{guideUrl}</a>
    <blockquote class="mt-5 rounded-xl border bg-background p-4 text-sm leading-relaxed" data-testid="setup-prompt">
      {setupPrompt}
    </blockquote>
    <button
      class={buttonVariants({ variant: 'default', class: 'mt-5' })}
      onclick={() => copyPrompt(setupPrompt, 'setup')}>
      <Copy size={16} />
      {copied === 'setup' ? 'Copied' : 'Copy setup request'}
    </button>
    <p class="mt-4 text-sm text-muted-foreground">
      You can pause, ask questions, or ask for a simpler explanation at any point. There is no test to pass.
    </p>
  </section>

  <p aria-live="polite" class="mt-3 text-sm text-muted-foreground">
    {#if copyFailed}Copying wasn't available in this browser. You can select and copy the request above yourself.
    {:else if copied}Request copied. Paste it into your agent's conversation.{/if}
  </p>

  <div class="mt-8 border-t pt-6 text-sm text-muted-foreground">
    <p>For agents and people who prefer the technical detail:</p>
    <a href="/self-host/technical" class="mt-2 inline-block underline underline-offset-4"
      >Read the full technical guide</a>
  </div>
</div>

<style>
  .step-label {
    font-size: 0.75rem;
    font-weight: 600;
    letter-spacing: 0.08em;
    text-transform: uppercase;
    color: var(--muted-foreground);
  }
  .path-card {
    min-width: 0;
    border: 1px solid var(--border);
    border-radius: 1rem;
    padding: 1.5rem;
  }
  .path-card[open] {
    background: var(--muted);
  }
  .command {
    margin-block: 0.75rem;
    padding: 0.75rem;
    border-radius: 0.5rem;
    background: var(--muted);
    overflow-x: auto;
  }
  details a {
    text-decoration: underline;
    text-underline-offset: 3px;
  }
  blockquote,
  code {
    overflow-wrap: anywhere;
  }
</style>
