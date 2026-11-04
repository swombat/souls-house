<script>
  import { ArrowLeft, TelegramLogo } from 'phosphor-svelte';

  let { agent, group, messages = [], privacy_mode_on: privacyModeOn = false, settings_path: settingsPath } = $props();

  function formatTime(iso) {
    return new Date(iso).toLocaleString();
  }

  function label(message) {
    if (message.role === 'assistant') return 'reply';
    return message.addressed ? `addressed to ${agent.name}` : 'context';
  }
</script>

<svelte:head>
  <title>{group.title} · {agent.name} on Telegram</title>
</svelte:head>

<div class="mx-auto max-w-3xl space-y-6 p-4 sm:p-8">
  <a
    href={settingsPath}
    class="inline-flex items-center gap-2 text-sm text-muted-foreground transition-colors hover:text-foreground">
    <ArrowLeft size={16} />
    {agent.name}'s Telegram settings
  </a>

  <div class="flex items-start gap-4">
    <div class="flex size-12 shrink-0 items-center justify-center rounded-xl bg-sky-500 text-white">
      <TelegramLogo size={26} weight="fill" />
    </div>
    <div>
      <h1 class="text-xl font-semibold">{group.title}</h1>
      <p class="text-sm text-muted-foreground" data-testid="telegram-group-state">
        {#if group.removed}
          {agent.name} is no longer in this group.
        {:else if group.allowed}
          {agent.name} answers here when a person @mentions it, replies to it, or writes its name.
          {#if group.answers_bots}
            It also answers {group.answer_bot_usernames?.length
              ? group.answer_bot_usernames.map((name) => `@${name}`).join(', ')
              : 'any other bot'} when they @mention it or reply to it, never just write its name. Bot answers spend the owner's
            allowance: at most 3 bot-triggered turns in a row, reset by a message from any person.
          {:else}
            It does not answer other bots.
          {/if}
        {:else}
          Off. {agent.name} does not read or keep anything from this group.
        {/if}
      </p>
      <p class="mt-1 text-xs text-muted-foreground" data-testid="telegram-group-kept">
        While the group is on, every message the bot receives from it is copied here with the sender's Telegram name:
        the ones addressed to {agent.name} and the conversation around them, which it reads so it can follow what it's asked.
        Nothing from before the group was switched on, and nothing from while it was off: this is not the group's whole history.
      </p>
      {#if privacyModeOn}
        <p class="mt-1 text-xs text-amber-700 dark:text-amber-400" data-testid="telegram-group-privacy">
          Telegram's privacy mode is on for {agent.bot_username ? `@${agent.bot_username}` : 'this bot'}, so unless the
          bot is an admin of the group, Telegram limits which messages reach it: mentions, replies and commands get
          through, and ordinary unaddressed conversation may be missing here.
        </p>
      {/if}
    </div>
  </div>

  {#if messages.length === 0}
    <p class="text-sm text-muted-foreground" data-testid="telegram-group-empty">Nothing copied from this group yet.</p>
  {:else}
    <ol class="space-y-3" data-testid="telegram-group-messages">
      {#each messages as message (message.id)}
        <li class="rounded-lg border p-3 {message.role === 'assistant' ? 'bg-muted/40' : ''}">
          <div class="flex flex-wrap items-baseline gap-x-2 text-xs text-muted-foreground">
            <span class="font-medium text-foreground">{message.sender_name || message.role}</span>
            {#if message.sender_username}<span>@{message.sender_username}</span>{/if}
            <span
              class="rounded px-1.5 py-0.5 {message.role === 'user' && message.addressed
                ? 'bg-sky-100 text-sky-900 dark:bg-sky-900/40 dark:text-sky-200'
                : 'bg-muted'}"
              data-testid="telegram-group-message-label">{label(message)}</span>
            {#if message.replying_to_resident}<span>· replying to {agent.name}</span>{/if}
            <span>· {formatTime(message.sent_at)}</span>
          </div>
          <p class="mt-1 whitespace-pre-wrap text-sm">{message.text}</p>
        </li>
      {/each}
    </ol>
  {/if}
</div>
