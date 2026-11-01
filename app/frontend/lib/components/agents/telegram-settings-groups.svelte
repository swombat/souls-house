<script>
  import TelegramGroupSettings from './telegram-group-settings.svelte';

  let { agent, username, configuration = null, groups = [], canManage = false } = $props();
</script>

<div class="rounded-lg bg-muted/50 p-4 space-y-3" data-testid="telegram-groups">
  <div>
    <p class="text-sm font-medium">Groups</p>
    <p class="text-xs text-muted-foreground">
      A group is off until an owner of this account, with their Telegram linked to @{username}, mentions it there for
      the first time, or switches it on here. In a group that is on, {agent.name} reads the conversation and answers when
      a person mentions @{username}, writes its name, or replies to it. Each of those answers spends a turn on this
      account's plan.
    </p>
    <p class="mt-2 text-xs text-muted-foreground" data-testid="telegram-bot-answer-cost">
      Answering other bots is off by default. If enabled, bots spend the owner's allowance too. At most 3 bot-triggered
      turns run in a row; a message from any person in the group resets that limit. Bots must @mention @{username}
      or reply to it: writing {agent.name}'s bare name never wakes it.
    </p>
  </div>
  {#if configuration?.reads_all_group_messages === false}
    <p class="text-xs text-amber-700 dark:text-amber-400" data-testid="telegram-groups-privacy">
      Telegram's privacy mode is on for @{username}. Unless the bot is a group admin, Telegram limits which messages
      reach it: mentions, replies and commands get through, and ordinary unaddressed conversation may be missing. To
      change that, send /setprivacy to @BotFather, pick @{username} and choose Disable, then remove the bot from each group
      and add it back (or make it a group admin).
    </p>
  {/if}
  {#if groups.length === 0}
    <p class="text-xs text-muted-foreground" data-testid="telegram-groups-empty">
      Add @{username} to a Telegram group and it will appear here, switched off.
    </p>
  {:else}
    <ul class="divide-y rounded-md border bg-background">
      {#each groups as group (group.id)}
        <TelegramGroupSettings {agent} {group} {canManage} />
      {/each}
    </ul>
    {#if !canManage}
      <p class="text-xs text-muted-foreground">
        Only an owner of this account can allow a group or change bot answers.
      </p>
    {/if}
  {/if}
</div>
