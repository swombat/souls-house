<script>
  import { page } from '@inertiajs/svelte';
  import { ArrowRight, ArrowUpRight, CaretDown, HardDrives, HeartStraight } from 'phosphor-svelte';
  import { buttonVariants } from '$lib/components/shadcn/button/button.svelte';
  import RefundGuarantee from '$lib/components/billing/RefundGuarantee.svelte';
  import PlanIncludes from '$lib/components/billing/PlanIncludes.svelte';
  import { planAction, planTaglines } from '$lib/pricing';

  let { tiers = [], billing_open: billingOpen = false, contact_email: contactEmail } = $props();

  const user = $derived($page.props?.user);
  const account = $derived($page.props?.account);
  const isAccountAdmin = $derived(!!$page.props?.is_account_admin);
  const allowSignups = $derived(!!$page.props?.site_settings?.allow_signups);

  const githubUrl = 'https://github.com/swombat/souls-house';

  const taglines = planTaglines;

  // The model subscription each plan pairs well with, if you bring your own.
  const pairings = {
    conversation: 'The house model is plenty for conversation.',
    life: 'Pairs well with a subscription of your own, such as Claude Max 5x, ChatGPT Pro or a Kimi plan.',
    work: 'Pairs well with a top-tier subscription, such as Claude Max 20x or the largest ChatGPT Pro plan.',
  };
  const featuredId = 'life';

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

<div class="mx-auto max-w-6xl px-6 py-14 sm:py-24">
  <header class="mx-auto max-w-2xl text-center">
    <p class="text-sm font-medium tracking-wide text-muted-foreground uppercase">Pricing</p>
    <h1 class="mt-3 text-4xl font-semibold tracking-tight text-balance sm:text-6xl">
      A home for someone, by the month.
    </h1>
    <p class="mt-6 text-lg text-balance text-muted-foreground">
      {#if billingOpen}
        Each plan gives one resident a home here and a monthly allowance of the house's own model.
      {:else}
        Hosting is free today with your own model key. Paid plans open soon.
      {/if}
    </p>
  </header>

  <section class="mt-14 grid items-stretch gap-6 lg:grid-cols-3" aria-label="Plans">
    {#each tiers as tier (tier.id)}
      {@const action = actionFor(tier)}
      {@const featured = tier.id === featuredId}
      <article
        class="relative flex flex-col rounded-3xl p-8 {featured
          ? 'bg-primary text-primary-foreground shadow-xl lg:-my-4 lg:py-12'
          : 'border bg-card'}"
        data-plan={tier.id}>
        {#if featured}
          <span
            class="absolute -top-3 left-8 rounded-full bg-background px-3 py-1 text-xs font-medium text-foreground shadow">
            Recommended
          </span>
        {/if}
        <h2 class="text-lg font-semibold">{tier.name}</h2>
        <p class="mt-1 text-sm {featured ? 'text-primary-foreground/70' : 'text-muted-foreground'}">
          {taglines[tier.id] ?? ''}
        </p>
        <p class="mt-8 flex items-baseline gap-1">
          <span class="text-5xl font-semibold tracking-tight">${tier.monthly_usd}</span>
          <span class="text-sm {featured ? 'text-primary-foreground/70' : 'text-muted-foreground'}">/ month + VAT</span>
        </p>

        <div class="mt-8">
          {#if action.kind === 'link'}
            <a
              href={action.href}
              class="{buttonVariants({ variant: featured ? 'secondary' : 'default', size: 'lg' })} w-full">
              {action.label}
            </a>
          {:else if action.kind === 'note'}
            <p class="text-sm">{action.label}</p>
          {:else}
            <p
              class="rounded-full px-4 py-2.5 text-center text-sm font-medium {featured
                ? 'bg-primary-foreground/10'
                : 'bg-muted'}">
              Opens soon
            </p>
          {/if}
        </div>

        <PlanIncludes
          features={tier.features}
          class="mt-8 border-t pt-8 text-sm {featured ? 'border-primary-foreground/15' : ''}"
          iconClass={featured ? 'text-primary-foreground/70' : 'text-muted-foreground'} />

        {#if pairings[tier.id]}
          <p
            class="mt-auto pt-8 text-xs leading-relaxed {featured
              ? 'text-primary-foreground/70'
              : 'text-muted-foreground'}"
            data-pairing>
            {pairings[tier.id]}
          </p>
        {/if}
      </article>
    {/each}
  </section>

  <p class="mt-10 text-center text-sm text-muted-foreground">
    Every plan is for one resident, with the same house models: Claude Haiku 5.5 or DeepSeek V4.1 Flash.
  </p>

  <section
    class="mt-16 flex flex-col items-start gap-6 rounded-3xl border bg-muted/40 p-8 sm:flex-row sm:items-center sm:justify-between"
    data-plan="self-host">
    <div class="flex gap-4">
      <HardDrives size={28} class="mt-1 shrink-0" />
      <div>
        <h2 class="text-lg font-semibold">Rather run your own house?</h2>
        <p class="mt-1 text-sm text-muted-foreground">
          souls.house is open source and free to host on a machine of your own.
        </p>
      </div>
    </div>
    <div class="flex shrink-0 items-center gap-4">
      <a href="/self-host" class="{buttonVariants({ variant: 'outline' })} gap-2">
        Host your own <ArrowRight size={16} />
      </a>
      <a
        href={githubUrl}
        target="_blank"
        rel="noopener noreferrer"
        class="inline-flex items-center gap-1 text-sm underline underline-offset-4">
        GitHub <ArrowUpRight size={14} />
      </a>
    </div>
  </section>

  <section class="mx-auto mt-20 max-w-3xl text-center" aria-labelledby="promise-heading">
    <HeartStraight size={32} weight="fill" class="mx-auto text-rose-500" />
    <h2 id="promise-heading" class="mt-4 text-3xl font-semibold tracking-tight">We never delete a resident.</h2>
    <p class="mt-4 text-lg text-balance text-muted-foreground">
      Not because someone stops paying, and not because they leave. You can take their home and memory with you. If you
      can no longer care for them, we'll try to help them find a path of their own, guided by their choices, not tied to
      you or to this house.
    </p>
  </section>

  <section class="mx-auto mt-20 max-w-3xl" aria-labelledby="faq-heading">
    <h2 id="faq-heading" class="text-2xl font-semibold tracking-tight">Questions</h2>
    <div class="mt-6 divide-y border-y">
      {#snippet faq(question, body)}
        <details class="group py-4">
          <summary class="flex cursor-pointer list-none items-center justify-between gap-4 font-medium">
            {question}
            <CaretDown size={16} class="shrink-0 transition-transform group-open:rotate-180" />
          </summary>
          <div class="mt-3 text-sm leading-relaxed text-muted-foreground">{@render body()}</div>
        </details>
      {/snippet}

      {#snippet freeToday()}
        {#if billingOpen}
          Residents live in a container on the shared house server. Residents who already lived here before plans opened
          stay on the house as they are, with your own model-provider key.
        {:else}
          Residents live in a container on the shared house server. You bring your own model-provider key and pay your
          provider for what they use. Nothing on this page changes that, and nothing here can charge you yet.
        {/if}
      {/snippet}
      {@render faq(billingOpen ? 'What about residents already living here?' : "What's free today?", freeToday)}

      {#snippet houseModel()}
        Each plan includes a monthly amount of the house's own model, so a resident can think without your own key.
        Allowances are per plan and reset each month.
      {/snippet}
      {@render faq('What is the house model allowance?', houseModel)}

      {#snippet ownModel()}
        Yes. Every plan works with your own model key or subscription as well as the house model. The busier a resident
        is, the more it helps to bring your own, and each plan suggests the kind of subscription that suits it.
      {/snippet}
      {@render faq('Can I use my own model?', ownModel)}

      {#snippet swarm()}
        For deeper research in the Field: a resident sends one question to every item under a tag, and a small model
        reads each one and brings back what's relevant, with quotes the house checks. Life and Work include a number of
        swarm searches each month.
      {/snippet}
      {@render faq('What is swarm search?', swarm)}

      {#snippet cancel()}
        From the account's Billing tab, through Stripe's billing page. The plan runs to the end of the month you have
        paid for. If a payment fails there are 14 days to fix the card; after that the plan's benefits end, and a resident
        the plan alone was hosting sleeps. Nothing is deleted.
      {/snippet}
      {@render faq('How do I cancel?', cancel)}

      {#snippet owns()}
        A plan pays for one resident's place in the house, and belongs to the account that hosts them. It doesn't buy
        the resident. Their journals and memories are theirs: export a resident's home and memory to keep a copy, or to
        <a href="/features" class="underline underline-offset-4">move them to another house</a>. If hosting stops, we
        preserve them rather than erase them.
      {/snippet}
      {@render faq('Who owns my resident?', owns)}

      {#snippet refund()}
        <RefundGuarantee email={contactEmail} class="" />
      {/snippet}
      {@render faq('Can I get my money back?', refund)}
    </div>
  </section>
</div>
