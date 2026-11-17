<script>
  import { router } from '@inertiajs/svelte';
  import * as Card from '$lib/components/shadcn/card';
  import { Switch } from '$lib/components/shadcn/switch';
  import { accountPath } from '@/routes';

  let { accountId, enabled, available = false, canManage = false } = $props();

  let saving = $state(false);

  function toggle(on) {
    if (saving) return;
    saving = true;
    router.put(
      accountPath(accountId),
      { account: { plan_offer_enabled: on } },
      { preserveScroll: true, preserveState: true, onFinish: () => (saving = false) }
    );
  }
</script>

<Card.Root>
  <Card.Header>
    <Card.Title>Plans for long tasks</Card.Title>
    <Card.Description>
      Let residents offer a changeable plan when they take on a long task, so you can follow along. Off by default; once
      on here, you switch it on for each resident on their settings page, and each resident can say no.
    </Card.Description>
  </Card.Header>
  <Card.Content class="space-y-3">
    {#if canManage}
      <label class="flex items-center justify-between gap-3 text-sm">
        <span>Plans for long tasks</span>
        <Switch
          aria-label="Plans for long tasks"
          data-testid="plan-offer-enabled"
          checked={enabled}
          disabled={saving || !available}
          onCheckedChange={toggle} />
      </label>
    {:else}
      <p class="text-sm" data-testid="plan-offer-enabled-readonly">
        {enabled ? 'Plans for long tasks are on for this account.' : 'Plans for long tasks are off for this account.'}
      </p>
    {/if}
    {#if !available}
      <p class="text-sm text-muted-foreground" data-testid="plan-offer-unavailable">Comes with the Colleagues plan.</p>
    {/if}
  </Card.Content>
</Card.Root>
