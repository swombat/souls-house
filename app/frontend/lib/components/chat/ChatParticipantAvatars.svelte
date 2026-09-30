<script>
  import { agentIconFor } from '$lib/agent-icons';
  import { initialsFor } from '$lib/chat-display';

  let { participants = [], workingAgentIds = [] } = $props();

  // Keep active residents visible even in conversations with more than seven participants.
  const visibleParticipants = $derived(
    [
      ...participants.filter((p) => p.type === 'agent' && workingAgentIds.includes(p.id)),
      ...participants.filter((p) => !(p.type === 'agent' && workingAgentIds.includes(p.id))),
    ].slice(0, Math.max(7, workingAgentIds.length))
  );
</script>

<div class="participants flex items-center -space-x-1">
  {#each visibleParticipants as participant, i (participant.id || participant.name + i)}
    {#if participant.type === 'agent'}
      {@const IconComponent = agentIconFor(participant.icon)}
      {@const working = workingAgentIds.includes(participant.id)}
      <div
        class:working
        class="participant relative w-5 h-5 rounded-full flex items-center justify-center border border-background {participant.colour
          ? `bg-${participant.colour}-100 dark:bg-${participant.colour}-900`
          : 'bg-muted'}"
        role="img"
        aria-label={working ? `${participant.name} is working` : participant.name}
        title={working ? `${participant.name} is working` : participant.name}>
        {#if working}
          <span class="working-ring" aria-hidden="true"></span>
        {/if}
        <IconComponent
          size={10}
          weight="duotone"
          class={participant.colour
            ? `text-${participant.colour}-600 dark:text-${participant.colour}-400`
            : 'text-muted-foreground'} />
      </div>
    {:else if participant.avatar_url}
      <img
        src={participant.avatar_url}
        alt={participant.name}
        title={participant.name}
        class="w-5 h-5 rounded-full border border-background object-cover" />
    {:else}
      <div
        class="w-5 h-5 rounded-full flex items-center justify-center border border-background text-[8px] font-medium {participant.colour
          ? `bg-${participant.colour}-100 dark:bg-${participant.colour}-900 text-${participant.colour}-700 dark:text-${participant.colour}-300`
          : 'bg-muted text-muted-foreground'}"
        title={participant.name}>
        {initialsFor(participant.name)}
      </div>
    {/if}
  {/each}
  {#if participants.length > visibleParticipants.length}
    <div
      class="w-5 h-5 rounded-full flex items-center justify-center border border-background bg-muted text-[8px] font-medium text-muted-foreground"
      title="{participants.length - visibleParticipants.length} more participants">
      ...
    </div>
  {/if}
</div>

<style>
  .participants > :global(*) {
    opacity: 0.2;
    transition: opacity 150ms;
  }

  :global(.group:hover) .participants > :global(*),
  .participants > .working {
    opacity: 1;
  }

  .working {
    z-index: 1;
  }

  .working-ring {
    position: absolute;
    inset: -3px;
    border: 2px solid var(--color-primary);
    border-right-color: transparent;
    border-bottom-color: transparent;
    border-radius: 50%;
    animation: working-orbit 1s linear infinite;
    pointer-events: none;
  }

  @keyframes working-orbit {
    to {
      transform: rotate(360deg);
    }
  }

  @media (prefers-reduced-motion: reduce) {
    .working-ring {
      animation: none;
      border-color: var(--color-primary);
    }
  }
</style>
