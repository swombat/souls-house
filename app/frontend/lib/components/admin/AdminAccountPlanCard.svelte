<script>
  import { router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '$lib/components/shadcn/card';

  // A plan given by the house (accounts.granted_plan), with nothing to pay.
  // The card says why the plan in force is what it is, and what changing the
  // grant does and does not do.
  let { account } = $props();

  const plan = $derived(account.plan);
  const plans = $derived(plan?.plans || []);
  const current = $derived(plan?.granted_plan || '');
  const accountId = $derived(account.id);
  let choice = $state('');
  // Follow the saved grant and the selected account, not every live refresh
  // of the account (both are strings, so an unchanged value does not rerun).
  $effect(() => {
    void accountId;
    choice = current;
  });

  const rank = (id) => plans.findIndex((entry) => entry.id === id);
  const nameOf = (id) => plans.find((entry) => entry.id === id)?.name || id;
  const changed = $derived(choice !== current);
  const lowering = $derived(changed && current !== '' && (choice === '' || rank(choice) < rank(current)));

  // plan_source says "grant" for any gift; given_by says whose gift wins.
  const sourceText = $derived.by(() => {
    if (plan?.source === 'subscription') return 'from the plan line on its bill';
    if (plan?.source === 'default') return 'the default';
    if (plan?.given_by === 'code') {
      const code = (plan.plan_codes || []).find((entry) => entry.plan === plan.id);
      return code ? `given by the code ${code.code}` : 'given by a plan code';
    }
    return 'given by the house';
  });

  function save() {
    router.patch(`/admin/accounts/${account.id}/granted_plan`, { account: { granted_plan: choice } });
  }
</script>

{#if plan}
  <section class="mb-8" aria-label="Account plan">
    <Card>
      <CardHeader>
        <CardTitle>Account plan</CardTitle>
        <CardDescription>
          Give this account a plan with nothing to pay. The account has the highest of the house's plan, a plan code's
          and a paid plan line.
        </CardDescription>
      </CardHeader>
      <CardContent>
        <p class="text-sm" data-testid="plan-in-force">
          On <strong>{plan.name}</strong>, {sourceText}.
        </p>
        {#if plan.subscription}
          <p class="mt-2 text-sm text-muted-foreground">
            Its bill has a {plan.subscription.plan_name || plan.subscription.plan} plan line ({plan.subscription
              .status}{plan.subscription.in_force ? '' : ', not in force'}). Giving a plan does not take that line off
            its bill.
          </p>
        {:else if plan.bill}
          <p class="mt-2 text-sm text-muted-foreground">
            It already has a bill, with no plan line on it. Giving a plan adds nothing to that bill.
          </p>
        {:else if plan.plan_to_pay_for}
          <p class="mt-2 text-sm text-muted-foreground">
            It has no bill yet. The first purchase that includes the plan's resident would carry a {nameOf(
              plan.plan_to_pay_for
            )} plan line.
          </p>
        {:else}
          <p class="mt-2 text-sm text-muted-foreground">
            It has no bill yet. The first purchase that includes the plan's resident would carry no plan line, because
            what it is given already covers it.
          </p>
        {/if}
        {#each plan.plan_codes || [] as code (code.code)}
          <p class="mt-2 text-sm text-muted-foreground">The code {code.code} gives it {code.plan_name || code.plan}.</p>
        {/each}

        <div class="mt-4 flex flex-col gap-3 md:flex-row md:items-end">
          <label class="flex-1 text-sm font-medium">
            Plan from the house
            <select
              class="mt-1 flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm"
              bind:value={choice}>
              <option value="">None</option>
              {#each plans as entry (entry.id)}
                <option value={entry.id}>{entry.name}</option>
              {/each}
            </select>
          </label>
          <Button onclick={save} disabled={!changed}>Save plan</Button>
        </div>
        {#if lowering}
          <p class="mt-2 text-sm text-muted-foreground" role="note">
            Nobody is removed from the account. It loses what {nameOf(current)} gives beyond {choice
              ? nameOf(choice)
              : 'its plan without this grant'}, unless a plan code or a paid plan line still gives it.
          </p>
        {/if}
      </CardContent>
    </Card>
  </section>
{/if}
