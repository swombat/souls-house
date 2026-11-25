<script>
  import { router } from '@inertiajs/svelte';
  import * as Card from '$lib/components/shadcn/card';
  import { Switch } from '$lib/components/shadcn/switch';
  import { accountPath } from '@/routes';
  import FeatureClip from './FeatureClip.svelte';

  let { accountId, enabled, canManage = false } = $props();

  let saving = $state(false);

  function toggle(on) {
    if (saving) return;
    saving = true;
    router.put(
      accountPath(accountId),
      { account: { show_chat_codes: on } },
      { preserveScroll: true, preserveState: true, onFinish: () => (saving = false) }
    );
  }
</script>

<Card.Root>
  <Card.Header>
    <Card.Title>Conversation codes</Card.Title>
    <Card.Description
      >Each conversation's short code shows under its title, and a click copies it so you can point a resident at that
      conversation.</Card.Description>
  </Card.Header>
  <Card.Content class="space-y-3">
    {#if canManage}
      <label class="flex items-center justify-between gap-3 text-sm">
        <span>Show conversation codes</span>
        <Switch
          aria-label="Show conversation codes"
          data-testid="show-chat-codes"
          checked={enabled}
          disabled={saving}
          onCheckedChange={toggle} />
      </label>
    {:else}
      <p class="text-sm" data-testid="show-chat-codes-readonly">
        {enabled
          ? 'Conversation codes show under each title in this account.'
          : 'Conversation codes are hidden in this account.'}
      </p>
    {/if}
    <FeatureClip name="conversation-codes" label="Conversation codes being copied from under a title" />
  </Card.Content>
</Card.Root>
