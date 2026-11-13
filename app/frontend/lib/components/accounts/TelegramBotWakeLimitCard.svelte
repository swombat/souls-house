<script>
  import { router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Input } from '$lib/components/shadcn/input/index.js';
  import { Label } from '$lib/components/shadcn/label/index.js';
  import * as Card from '$lib/components/shadcn/card';
  import { accountPath } from '@/routes';
  import { createAccountSettingDraft } from '$lib/account-setting-draft.svelte.js';

  let { accountId, limit, canManage = false } = $props();

  const draft = createAccountSettingDraft(
    () => accountId,
    () => limit
  );
  const parsed = $derived(Number(draft.value));
  const valid = $derived(draft.value !== '' && Number.isInteger(parsed) && parsed >= 0 && parsed <= 50);
  const changed = $derived(valid && parsed !== limit);

  function save(event) {
    event.preventDefault();
    if (!changed || draft.saving) return;

    draft.save(
      (value, options) =>
        router.put(accountPath(accountId), { account: { telegram_bot_wake_limit: Number(value) } }, options),
      (response) => response.props.telegram_bot_wake_limit
    );
  }
</script>

<Card.Root>
  <Card.Header>
    <Card.Title>Telegram bot answers</Card.Title>
    <Card.Description>
      In a Telegram group that lets other bots wake a resident, the resident answers bots at most this many times in a
      row; then it waits until a person writes in the group. Every answer to a bot spends this account's allowance, the
      same as an answer to a person, so a high number lets two bots talk for a long time on your allowance. 0 means
      residents never answer bots.
    </Card.Description>
  </Card.Header>
  <Card.Content>
    {#if canManage}
      <form class="flex flex-col gap-3 sm:flex-row sm:items-end" onsubmit={save}>
        <div class="space-y-2">
          <Label for="telegram-bot-wake-limit">Bot answers between messages from a person</Label>
          <Input
            id="telegram-bot-wake-limit"
            type="number"
            min="0"
            max="50"
            step="1"
            class="w-32"
            bind:value={draft.value}
            data-testid="telegram-bot-wake-limit" />
        </div>
        <Button type="submit" disabled={!changed || draft.saving}>{draft.saving ? 'Saving…' : 'Save'}</Button>
      </form>
    {:else}
      <p class="text-sm" data-testid="telegram-bot-wake-limit-readonly">
        {limit === 0 ? 'Residents never answer bots.' : `Up to ${limit} in a row.`}
      </p>
    {/if}
  </Card.Content>
</Card.Root>
