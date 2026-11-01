<script>
  import { Button } from '$lib/components/shadcn/button';
  import { Input } from '$lib/components/shadcn/input';
  import { Label } from '$lib/components/shadcn/label';
  import { Switch } from '$lib/components/shadcn/switch';
  import { router } from '@inertiajs/svelte';

  let { agent, group, canManage = false } = $props();
  let saving = $state(false);
  let usernames = $state('');
  const usernamesKey = $derived(JSON.stringify([group.id, group.answer_bot_usernames ?? []]));
  $effect(() => {
    usernames = JSON.parse(usernamesKey)[1].join(', ');
  });

  function save(attributes) {
    saving = true;
    router.patch(group.path, attributes, {
      preserveScroll: true,
      preserveState: true,
      onFinish: () => (saving = false),
    });
  }

  function saveUsernames() {
    save({ answer_bot_usernames: usernames.split(/[\s,]+/).filter(Boolean) });
  }
</script>

<li class="space-y-3 p-3 text-sm" data-testid="telegram-group">
  <div class="flex items-center justify-between gap-3">
    <div class="min-w-0">
      <a href={group.path} class="font-medium underline-offset-4 hover:underline">{group.title}</a>
      <p class="text-xs text-muted-foreground">
        {#if group.removed}
          The bot is no longer in this group.
        {:else if group.allowed}
          Allowed{group.allowed_by ? ` by ${group.allowed_by}` : ''} · {group.message_count} message{group.message_count ===
          1
            ? ''
            : 's'} copied
        {:else if group.allowed_at}
          Off: switched off here, so nothing from this group is read or kept until it is switched back on.
        {:else}
          Off: nothing from this group is read or kept until an owner mentions the bot there.
        {/if}
      </p>
    </div>
    {#if canManage}
      <Switch
        aria-label={`Allow ${agent.name} in ${group.title}`}
        data-testid="telegram-group-allowed"
        checked={group.allowed}
        disabled={saving || (group.removed && !group.allowed)}
        onCheckedChange={(allowed) => save({ allowed })} />
    {:else}
      <span class="text-xs text-muted-foreground">{group.allowed ? 'Allowed' : 'Off'}</span>
    {/if}
  </div>
  <div class="flex items-center justify-between gap-3">
    {#if canManage}
      <Label for={`answer-bots-${group.id}`}>Answer other bots in this group</Label>
      <Switch
        id={`answer-bots-${group.id}`}
        aria-label={`Answer other bots in ${group.title}`}
        checked={group.answers_bots ?? false}
        disabled={saving || group.removed}
        onCheckedChange={(answers_bots) => save({ answers_bots })} />
    {:else}
      <span>Answer other bots in this group</span>
      <span class="text-xs text-muted-foreground">{group.answers_bots ? 'On' : 'Off'}</span>
    {/if}
  </div>
  {#if canManage}
    <div class="space-y-2">
      <Label for={`answer-bot-usernames-${group.id}`}>Bot usernames (optional)</Label>
      <div class="flex flex-wrap gap-2">
        <Input
          id={`answer-bot-usernames-${group.id}`}
          aria-label={`Bot usernames for ${group.title}`}
          class="min-w-40 flex-1"
          bind:value={usernames}
          placeholder="Any bot"
          disabled={saving || group.removed} />
        <Button type="button" variant="outline" size="sm" disabled={saving || group.removed} onclick={saveUsernames}>
          Save bot list
        </Button>
      </div>
      <p class="text-xs text-muted-foreground">
        Separate usernames with commas or spaces, with or without @. Empty means any bot when bot answers are on. You
        can prepare the list while bot answers are off.
      </p>
    </div>
  {:else if group.answers_bots}
    <p class="text-xs text-muted-foreground">
      Bots allowed: {group.answer_bot_usernames?.length
        ? group.answer_bot_usernames.map((name) => `@${name}`).join(', ')
        : 'any bot'}.
    </p>
  {/if}
</li>
