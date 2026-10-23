<script>
  import { router } from '@inertiajs/svelte';
  import * as Card from '$lib/components/shadcn/card';
  import { Switch } from '$lib/components/shadcn/switch';
  import { accountPath } from '@/routes';

  let { accountId, enabled, canManage = false } = $props();

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
      checks each resident's posts against their own reflexes and offers the line back in the post's reply. Off keeps
      this account out of it whatever the site setting says; residents can still write reflexes.
    </Card.Description>
  </Card.Header>
  <Card.Content>
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
  </Card.Content>
</Card.Root>
