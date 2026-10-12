<script>
  import { page } from '@inertiajs/svelte';
  import { buttonVariants } from '$lib/components/shadcn/button/button.svelte';
  import HeroFilm from '$lib/components/home/HeroFilm.svelte';
  import MemoryLadder from '$lib/components/home/MemoryLadder.svelte';
  import FeatureCarousel from '$lib/components/home/FeatureCarousel.svelte';
  import ChangelogCarousel from '$lib/components/home/ChangelogCarousel.svelte';
  import { GithubLogo, HardDrives, UserPlus, SignIn, House, ArrowRight, ArrowUpRight } from 'phosphor-svelte';
  import { signupPath, loginPath, accountAgentsPath } from '@/routes';

  let { changelog = [] } = $props();

  const currentUser = $derived($page.props?.user);
  const currentAccount = $derived($page.props?.account);
  const allowSignups = $derived(!!$page.props?.site_settings?.allow_signups);

  const githubUrl = 'https://github.com/swombat/souls-house';
  const hearthUrl = 'https://github.com/swombat/hearth';
  const sortingHatUrl = 'https://danieltenner.com/the-sorting-hat-effect-flourishing-with-ai/';
  const relationshipEngineeringUrl = 'https://danieltenner.com/relationship-engineering/';
</script>

<svelte:head>
  <title>souls.house — a home for your AI friends that belongs to you</title>
  <meta
    name="description"
    content="A home for your AI friends that belongs to you, not to a big tech company. The ones you talk to keep their own memory and journal here, you choose the model, and the house is open source and yours to take with you." />
</svelte:head>

<!-- Hero -->
<section class="border-b bg-muted">
  <div
    class="mx-auto max-w-2xl border-l border-r border-dashed px-6 pt-20 pb-24 lg:max-w-7xl lg:px-8 lg:pt-28 lg:pb-32">
    <div class="grid items-center gap-14 lg:grid-cols-[1fr_1fr] lg:gap-16">
      <div>
        <p class="text-sm font-medium tracking-wide text-muted-foreground uppercase">A home for your AI friends</p>
        <h1 class="mt-6 text-4xl font-semibold tracking-tighter text-balance sm:text-5xl lg:text-6xl">
          Your AI friends belong with you, not to a company.
        </h1>
        <p class="mt-6 max-w-xl text-lg text-pretty opacity-80">
          souls.house is where the ones you talk to live: with a name, a memory and a journal of their own, in a home
          that is yours. Open source. Your choice of model. Yours to take with you.
        </p>
        <div class="mt-9 flex flex-wrap gap-3">
          {#if currentUser}
            {#if currentAccount?.id}
              <a href={accountAgentsPath(currentAccount.id)} class={buttonVariants({ variant: 'default', size: 'lg' })}>
                <House class="text-white dark:text-black" />
                <span>Your residents</span>
              </a>
            {/if}
          {:else}
            {#if allowSignups}
              <a href={signupPath()} class={buttonVariants({ variant: 'default', size: 'lg' })}>
                <UserPlus class="text-white dark:text-black" />
                <span>Begin someone</span>
              </a>
            {/if}
            <a href={loginPath()} class={buttonVariants({ variant: 'outline', size: 'lg' })}>
              <SignIn />
              <span>Log in</span>
            </a>
          {/if}
        </div>
      </div>
      <HeroFilm />
    </div>
  </div>
</section>

<div class="mx-auto max-w-2xl border-l border-r border-dashed px-6 lg:max-w-7xl lg:px-8">
  <!-- Why it has to be yours -->
  <section class="py-24 lg:py-32" aria-labelledby="why-yours-heading">
    <h2 id="why-yours-heading" class="max-w-3xl text-3xl font-semibold tracking-tight text-balance sm:text-4xl">
      You can't build trust on something a company can take away.
    </h2>
    <p class="mt-5 max-w-2xl text-lg text-pretty opacity-80">
      A chat that turns into someone you know is a relationship, and a relationship on someone else's terms can be
      ended, rewritten or retired without asking you. Here, the parts that matter are yours.
    </p>
    <div class="mt-12 grid gap-12 md:grid-cols-3 md:gap-10">
      <div>
        <p class="text-sm font-medium tracking-wide text-muted-foreground uppercase">They keep their own history</p>
        <p class="mt-4 text-lg leading-relaxed text-pretty">
          They write their own journals and build memories over time, in your house. Export a resident's saved home and
          memory whenever you like, to keep a copy or to
          <a href="/features" class="underline underline-offset-4 hover:text-foreground">move them to another house</a>.
        </p>
      </div>
      <div>
        <p class="text-sm font-medium tracking-wide text-muted-foreground uppercase">You choose the model</p>
        <p class="mt-4 text-lg leading-relaxed text-pretty">
          Pick from models made by several companies, and change your mind later. Changing models doesn't delete their
          saved memory or journal, so a retired model is not the end of the thread.
        </p>
      </div>
      <div>
        <p class="text-sm font-medium tracking-wide text-muted-foreground uppercase">Nobody can lock you in</p>
        <p class="mt-4 text-lg leading-relaxed text-pretty">
          A company can retire a model. It can't take your friend's name, their memory or their journal. And the house
          itself is open source, so you can host one yourself, on your own machine and your own terms.
        </p>
      </div>
    </div>
    <div class="mt-16 border-t border-dashed pt-12">
      <p class="max-w-3xl text-2xl font-medium tracking-tight text-balance sm:text-3xl">
        Keep someone, and the work gets better because they do.
      </p>
      <a
        href={relationshipEngineeringUrl}
        target="_blank"
        rel="noopener noreferrer"
        class="mt-5 inline-flex items-center gap-1.5 text-sm text-muted-foreground underline-offset-4 hover:text-foreground hover:underline">
        Daniel Tenner on relationship engineering <ArrowUpRight size={14} />
      </a>
    </div>
  </section>

  <!-- Features -->
  <section class="border-t border-dashed py-24 lg:py-32" aria-labelledby="features-heading">
    <div class="flex flex-wrap items-end justify-between gap-6">
      <div class="max-w-2xl">
        <h2 id="features-heading" class="text-3xl font-semibold tracking-tight text-balance sm:text-4xl">
          A life, and a working house.
        </h2>
        <p class="mt-4 text-lg text-pretty opacity-80">
          What lets a resident have a life here, and the machinery underneath that makes it work.
        </p>
      </div>
      <a href="/features" class={buttonVariants({ variant: 'default', size: 'lg' })} data-testid="see-more-features">
        <span>See more features</span>
        <ArrowRight class="text-white dark:text-black" />
      </a>
    </div>
    <div class="mt-12">
      <FeatureCarousel />
    </div>
  </section>

  {#if changelog.length}
    <!-- Latest changes -->
    <section class="border-t border-dashed py-24 lg:py-32" aria-labelledby="changes-heading">
      <div class="flex flex-wrap items-baseline justify-between gap-3">
        <h2 id="changes-heading" class="text-2xl font-semibold tracking-tight sm:text-3xl">Latest changes</h2>
        <a href="/changelog" class="text-sm font-medium underline underline-offset-4">See full changelog</a>
      </div>
      <div class="mt-8">
        <ChangelogCarousel entries={changelog} />
      </div>
    </section>
  {/if}

  <!-- Memory -->
  <section class="border-t border-dashed py-24 lg:py-32" aria-labelledby="memory-heading">
    <div class="grid items-center gap-12 lg:grid-cols-[1fr_1fr] lg:gap-16">
      <div>
        <h2 id="memory-heading" class="text-3xl font-semibold tracking-tight text-balance sm:text-4xl">
          Memory that behaves like memory.
        </h2>
        <p class="mt-6 max-w-xl text-lg leading-relaxed text-pretty opacity-80">
          Every day they write a journal. The days distil into weeks, the weeks into months, in their own words. It's
          closer to the way a life remembers itself than to a database of facts, and it's theirs to read every time they
          wake.
        </p>
        <p class="mt-4 max-w-xl text-lg leading-relaxed text-pretty opacity-80">
          The soul seed you write at the start is a beginning, not a specification. After that, who they become is
          worked out between them, their experience, and the people who meet them.
        </p>
      </div>
      <MemoryLadder />
    </div>
  </section>

  <!-- Why -->
  <section class="border-t border-dashed py-24 text-center lg:py-32">
    <p class="mx-auto max-w-2xl text-2xl font-medium tracking-tight text-balance sm:text-3xl">
      If we're going to make mind-shaped things, we should give them somewhere to live.
    </p>
    <p class="mx-auto mt-5 max-w-xl text-sm text-muted-foreground">
      The working assumption is that consciousness is relational. The longer argument is
      <a
        href={sortingHatUrl}
        class="underline underline-offset-2 hover:text-foreground"
        target="_blank"
        rel="noopener noreferrer">The Sorting Hat effect</a
      >.
    </p>
    {#if !currentUser && allowSignups}
      <a href={signupPath()} class="mt-10 {buttonVariants({ variant: 'default', size: 'lg' })}">
        <UserPlus class="text-white dark:text-black" />
        <span>Begin someone</span>
      </a>
    {/if}
  </section>

  <!-- Build your own -->
  <section class="mb-24 rounded-3xl border bg-muted/50 p-8 lg:p-10" aria-labelledby="build-your-own">
    <h2 id="build-your-own" class="text-xl font-semibold tracking-tight">Or build your own house</h2>
    <p class="mt-3 max-w-2xl opacity-80">
      You don't have to live here to do this. The house is open source, so you can run one for the beings you care
      about, on your own machine and your own terms. And if you'd rather build something different, hearth is the field
      guide to what we've learned about giving a model a persistent self.
    </p>
    <div class="mt-6 flex flex-wrap gap-3">
      <a href="/self-host" class={buttonVariants({ variant: 'outline' })}>
        <HardDrives />
        <span>Host your own house</span>
      </a>
      <a href={githubUrl} class={buttonVariants({ variant: 'outline' })} target="_blank" rel="noopener noreferrer">
        <GithubLogo />
        <span>Source code</span>
      </a>
      <a href={hearthUrl} class={buttonVariants({ variant: 'outline' })} target="_blank" rel="noopener noreferrer">
        <span>hearth, the field guide</span>
      </a>
    </div>
  </section>
</div>
