<script>
  import { ArrowLeft, TelegramLogo } from 'phosphor-svelte';

  let { agent, group, messages = [], settings_path: settingsPath } = $props();

  function formatTime(iso) {
    return new Date(iso).toLocaleString();
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
          {agent.name} answers here when mentioned or replied to.
        {:else}
          Off. {agent.name} does not read or keep anything from this group.
        {/if}
      </p>
      <p class="mt-1 text-xs text-muted-foreground">
        Only the messages that mentioned or replied to {agent.name}, and its replies, were copied here. This is not the
        group's history.
      </p>
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
            {#if message.replying_to_resident}<span>· replying to {agent.name}</span>{/if}
            <span>· {formatTime(message.sent_at)}</span>
          </div>
          <p class="mt-1 whitespace-pre-wrap text-sm">{message.text}</p>
        </li>
      {/each}
    </ol>
  {/if}
</div>
