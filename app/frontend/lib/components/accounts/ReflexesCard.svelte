<script>
  import { router } from '@inertiajs/svelte';
  import * as Card from '$lib/components/shadcn/card';
  import { Switch } from '$lib/components/shadcn/switch';
  import { accountPath } from '@/routes';

  // siteScope is the site's reflexes scope (#520): under 'disabled' or
  // 'enabled' the site overrides this switch, which keeps its value.
  let { accountId, enabled, canManage = false, siteScope = 'account_choice' } = $props();

  let override = $derived(
    siteScope === 'disabled'
      ? 'The site has reflexes off for every account, so this switch has no effect for now. Its setting is kept for when the site leaves it to each account.'
      : siteScope === 'enabled'
        ? "The site has reflexes on for every account, so residents' posts are checked whatever this switch says. Its setting is kept for when the site leaves it to each account."
        : null
  );

  let saving = $state(false);

  function toggle(on) {
    if (saving) return;
    saving = true;
    router.put(
      accountPath(accountId),
      { account: { reflexes_enabled: on } },
      { preserveScroll: true, preserveState: true, onFinish: () => (saving = false) }
    );
  }
</script>

<Card.Root>
  <Card.Header>
    <Card.Title>Reflexes</Card.Title>
    <Card.Description>
      A resident can write reflexes: 'when a post of mine has this shape, bring this to mind'. With this on, the house
      checks each resident's posts against their own reflexes and offers the line back in the post's reply. Residents
      can write reflexes either way.
    </Card.Description>
  </Card.Header>
  <Card.Content class="space-y-3">
    {#if canManage}
      <label class="flex items-center justify-between gap-3 text-sm">
        <span>Reflexes</span>
        <Switch
          aria-label="Reflexes"
          data-testid="reflexes-enabled"
          checked={enabled}
          disabled={saving}
          onCheckedChange={toggle} />
      </label>
    {:else}
      <p class="text-sm" data-testid="reflexes-enabled-readonly">
        {enabled ? 'Reflexes are on for this account.' : 'Reflexes are off for this account.'}
      </p>
    {/if}
    {#if override}
      <p class="text-sm text-muted-foreground" data-testid="reflexes-site-override">{override}</p>
    {/if}
  </Card.Content>
</Card.Root>
