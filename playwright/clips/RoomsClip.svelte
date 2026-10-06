<script>
  // Rooms with others: one person and two residents in the same conversation, the residents answering each other.
  import MessageBubble from '$lib/components/chat/MessageBubble.svelte';
  import { Feather, Leaf, User } from 'phosphor-svelte';
  import { typed, loopFade, arrive, ease, ramp } from './timeline.js';

  let { t = 0 } = $props();
  const DURATION = 15;

  const script = [
    { role: 'user', who: 'Sam', at: 0.6, text: 'Planning Saturday. Market first, or the hill walk?' },
    {
      role: 'assistant',
      who: 'Wren',
      colour: 'teal',
      at: 2.4,
      text: "Hill walk first. The light's better before ten, and the market will still be there at noon.",
    },
    {
      role: 'assistant',
      who: 'Juniper',
      colour: 'amber',
      at: 5.6,
      text: "Wren's right about the light. But the good bread is gone by eleven.",
    },
    {
      role: 'assistant',
      who: 'Wren',
      colour: 'teal',
      at: 8.4,
      text: 'Then we take the long way up, past the bakery. Fair, Juniper?',
    },
    { role: 'assistant', who: 'Juniper', colour: 'amber', at: 10.8, text: 'Fair. Sam carries the bread.' },
    { role: 'user', who: 'Sam', at: 12.6, text: 'Deal 😄' },
  ];

  let messages = $derived(
    script
      .filter((m) => t >= m.at)
      .map((m, i) => {
        const typing = m.role === 'assistant' ? 0.9 + m.text.length / 70 : 0;
        return {
          id: `m${i}`,
          role: m.role,
          content: m.role === 'assistant' ? typed(m.text, t, m.at + 0.3, m.at + 0.3 + typing) : m.text,
          streaming: m.role === 'assistant' && t < m.at + 0.3 + typing,
          created_at: new Date(Date.UTC(2026, 9, 3, 7, 12 + i)).toISOString(),
          author_name: m.who,
          author_colour: m.colour,
          at: m.at,
        };
      })
  );
  // Keep the newest messages in view, like a chat scrolled to the bottom.
  let shift = $derived(
    ease(ramp(t, 8.2, 8.9)) * 150 + ease(ramp(t, 10.6, 11.3)) * 110 + ease(ramp(t, 12.4, 13.0)) * 80
  );
</script>

<div
  class="clip-stage relative overflow-hidden bg-muted"
  style="width: 1280px; height: 720px; font-family: Inter, ui-sans-serif, system-ui, sans-serif;">
  <div class="absolute inset-0" style="opacity: {loopFade(t, DURATION)}">
    <div
      class="absolute left-1/2 top-0 h-full"
      style="width: 720px; transform: translateX(-50%) scale(1.38); transform-origin: top center">
      <div class="flex items-center gap-3 border-b bg-background px-5 py-3">
        <p class="font-semibold">Saturday</p>
        <div class="ml-auto flex items-center gap-1.5 text-xs text-muted-foreground">
          <span class="inline-flex items-center gap-1 rounded-md border px-2 py-0.5"><User size={12} /> Sam</span>
          <span class="inline-flex items-center gap-1 rounded-md border border-teal-300 px-2 py-0.5 text-teal-700"
            ><Feather size={12} weight="duotone" /> Wren</span>
          <span class="inline-flex items-center gap-1 rounded-md border border-amber-300 px-2 py-0.5 text-amber-700"
            ><Leaf size={12} weight="duotone" /> Juniper</span>
        </div>
      </div>
      <div class="overflow-hidden" style="height: 470px">
        <div class="space-y-4 px-5 pt-5" style="transform: translateY({-shift}px)">
          {#each messages as message (message.id)}
            <div style={arrive(t, message.at, 14, 0.35)}>
              <MessageBubble {message} isGroupChat={true} />
            </div>
          {/each}
        </div>
      </div>
    </div>
  </div>
</div>
