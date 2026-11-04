<script>
  import AgentAvatar from '$lib/components/agents/AgentAvatar.svelte';

  let { agents = [], messages = [] } = $props();

  // Extract unique human participants from messages
  const humanParticipants = $derived(() => {
    if (!messages || messages.length === 0) return [];

    const humans = new Map();
    messages.forEach((m) => {
      if (m.author_type === 'human' && m.author_name) {
        if (!humans.has(m.author_name)) {
          humans.set(m.author_name, {
            name: m.author_name,
            avatarUrl: m.user_avatar_url,
            colour: m.author_colour,
          });
        }
      }
    });
    return Array.from(humans.values());
  });

  // Get initials from a name
  function getInitials(name) {
    if (!name) return '?';
    return name
      .split(' ')
      .map((part) => part.charAt(0))
      .slice(0, 2)
      .join('')
      .toUpperCase();
  }
</script>

<div class="flex items-center -space-x-1.5">
  <!-- AI Agent avatars -->
  {#each agents as agent (agent.id)}
    <AgentAvatar
      {agent}
      class="w-6 h-6 rounded-full flex items-center justify-center border-2 border-background"
      fallbackClass={agent.colour ? `bg-${agent.colour}-100 dark:bg-${agent.colour}-900` : 'bg-muted'}
      iconClass={agent.colour ? `text-${agent.colour}-600 dark:text-${agent.colour}-400` : 'text-muted-foreground'}
      iconSize={12} />
  {/each}

  <!-- Human participant avatars -->
  {#each humanParticipants() as human (human.name)}
    {#if human.avatarUrl}
      <img
        src={human.avatarUrl}
        alt={human.name}
        title={human.name}
        class="w-6 h-6 rounded-full border-2 border-background object-cover" />
    {:else}
      <div
        class="w-6 h-6 rounded-full flex items-center justify-center border-2 border-background text-[10px] font-medium {human.colour
          ? `bg-${human.colour}-100 dark:bg-${human.colour}-900 text-${human.colour}-700 dark:text-${human.colour}-300`
          : 'bg-muted text-muted-foreground'}"
        title={human.name}>
        {getInitials(human.name)}
      </div>
    {/if}
  {/each}
</div>
