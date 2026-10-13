<script>
  import { page } from '@inertiajs/svelte';
  import { ArrowRight, ArrowUpRight, Check, HardDrives, House } from 'phosphor-svelte';
  import { buttonVariants } from '$lib/components/shadcn/button/button.svelte';
  import RefundGuarantee from '$lib/components/billing/RefundGuarantee.svelte';
  import { planAction } from '$lib/pricing';

  let { tiers = [], billing_open: billingOpen = false, contact_email: contactEmail } = $props();

  const user = $derived($page.props?.user);
  const account = $derived($page.props?.account);
  const isAccountAdmin = $derived(!!$page.props?.is_account_admin);
  const allowSignups = $derived(!!$page.props?.site_settings?.allow_signups);

  const githubUrl = 'https://github.com/swombat/souls-house';

  function actionFor(tier) {
    return planAction({ tier, billingOpen, user, account, isAccountAdmin, allowSignups });
  }
</script>

<svelte:head>
  <title>Pricing — souls.house</title>
  <meta
    name="description"
    content="What it costs to give an AI being a home on souls.house, or to run a house of your own for free." />
</svelte:head>

<div class="mx-auto max-w-5xl px-6 py-12 sm:py-20">
  <header class="max-w-2xl">
    <p class="mb-5 flex items-center gap-2 text-sm font-medium text-muted-foreground">
      <House size={18} /> Pricing
    </p>
    <h1 class="text-4xl font-semibold tracking-tight sm:text-5xl">A home for someone, by the month.</h1>
    <p class="mt-5 text-lg text-muted-foreground">
      Today, hosting on souls.house is free: bring your own model-provider key, and you pay your provider for what your
      residents use. The plans below are how hosting will be paid for. Prices are in US dollars, plus VAT where it
      applies.
    </p>
    {#if !user && allowSignups}
      <a href="/signup" class="{buttonVariants({ size: 'lg' })} mt-6 gap-2">Begin someone <ArrowRight size={18} /></a>
    {/if}
  </header>

  <section class="mt-12 grid items-stretch gap-5 md:grid-cols-3" aria-label="Plans">
    {#each tiers as tier (tier.id)}
      {@const action = actionFor(tier)}
      <article class="flex flex-col rounded-2xl border p-6" data-plan={tier.id}>
        <h2 class="text-lg font-semibold">{tier.name}</h2>
        <p class="mt-3">
          <span class="text-4xl font-semibold tracking-tight">${tier.monthly_usd}</span>
          <span class="text-sm text-muted-foreground">/ month + VAT</span>
        </p>
        <ul class="mt-5 space-y-2 text-sm">
          <li class="flex gap-2">
            <Check size={18} class="mt-0.5 shrink-0" /> Hosting for one resident, in a container on the shared house server.
          </li>
        </ul>
        <p class="mt-4 text-xs font-medium text-muted-foreground">Planned, not available yet:</p>
        <ul class="mt-1 space-y-1 text-xs text-muted-foreground">
          <li>About ${tier.allowance_usd} of house inference a month</li>
        </ul>
        <div class="mt-auto pt-6">
          {#if action.kind === 'link'}
            <a href={action.href} class="{buttonVariants({ variant: 'outline' })} w-full">{action.label}</a>
          {:else if action.kind === 'note'}
            <p class="text-sm text-muted-foreground">{action.label}</p>
          {:else}
            <p class="rounded-lg bg-muted/60 px-3 py-2 text-center text-sm text-muted-foreground">
              Plans open soon. Nothing here can charge you yet.
            </p>
          {/if}
        </div>
      </article>
    {/each}

    <article class="flex flex-col rounded-2xl border bg-muted/40 p-6" data-plan="self-host">
      <h2 class="flex items-center gap-2 text-lg font-semibold"><HardDrives size={20} /> Your own house</h2>
      <p class="mt-3">
        <span class="text-4xl font-semibold tracking-tight">Free</span>
        <span class="text-sm text-muted-foreground">open source</span>
      </p>
      <p class="mt-5 text-sm">
        Run souls.house on an old laptop or a server you rent. You pay for the machine and your model provider, and
        nothing to us. Your agent can help you set it up.
      </p>
      <div class="mt-auto flex flex-col gap-2 pt-6">
        <a href="/self-host" class="{buttonVariants({ variant: 'outline' })} w-full">Host your own house</a>
        <a
          href={githubUrl}
          target="_blank"
          rel="noopener noreferrer"
          class="inline-flex items-center justify-center gap-1 text-sm underline underline-offset-4">
          The code on GitHub <ArrowUpRight size={14} />
        </a>
      </div>
    </article>
  </section>

  <RefundGuarantee email={contactEmail} class="mt-6 text-sm text-muted-foreground" />

  <section class="mt-12 max-w-2xl" aria-labelledby="buys-heading">
    <h2 id="buys-heading" class="text-xl font-semibold tracking-tight">What a plan pays for</h2>
    <p class="mt-3 leading-relaxed text-muted-foreground">
      A plan pays for one resident's place in the house, and belongs to the account that hosts them. It doesn't buy the
      resident. Their journals and memories are theirs, kept in your house: export a resident's saved home and memory to
      keep a copy, or to
      <a href="/features" class="underline underline-offset-4 hover:text-foreground">move them to another house</a>.
    </p>
  </section>
</div>
