<script>
  // Rhythms: standing invitations appear on the real rhythms list; the clock reaches one,
  // it opens a conversation, and a quiet answer is a fine answer.
  import RhythmCard from '$lib/components/rhythms/RhythmCard.svelte';
  import MessageBubble from '$lib/components/chat/MessageBubble.svelte';
  import { Clock } from 'phosphor-svelte';
  import { ramp, ease, typed, loopFade, arrive } from './timeline.js';

  let { t = 0 } = $props();
  const DURATION = 15;
  const wren = { id: 1, name: 'Wren', icon: 'Feather', colour: 'teal' };
  const juniper = { id: 2, name: 'Juniper', icon: 'Leaf', colour: 'amber' };
  const creator = { name: 'Sam' };

  const rhythms = [
    {
      id: 1,
      title: 'Morning check-in',
      schedule_description: 'Every weekday at 08:30',
      state: 'active',
      residents: [wren],
      creator,
      next_run_at: '2026-10-06T06:30:00Z',
      timezone: 'Europe/Madrid',
      at: 0.7,
    },
    {
      id: 2,
      title: 'Sunday review',
      schedule_description: 'Weekly on Sunday at 18:00',
      state: 'active',
      residents: [wren, juniper],
      creator,
      next_run_at: '2026-10-11T16:00:00Z',
      timezone: 'Europe/Madrid',
      at: 1.5,
    },
    {
      id: 3,
      title: 'The day we met',
      schedule_description: 'Yearly on 10 March',
      state: 'active',
      residents: [wren],
      creator,
      next_run_at: '2027-03-10T09:00:00Z',
      timezone: 'Europe/Madrid',
      at: 2.3,
    },
  ];

  let minute = $derived(t < 4.6 ? '08:29' : '08:30');
  let tick = $derived(ease(ramp(t, 4.6, 4.9)));
  let glow = $derived(ease(ramp(t, 4.7, 5.2)) * (1 - ease(ramp(t, 6.4, 6.8))));
  let sceneOne = $derived(1 - ease(ramp(t, 6.6, 7.0)));
  let sceneTwo = $derived(ease(ramp(t, 7.1, 7.6)));

  const invitation = {
    id: 'r1',
    role: 'user',
    content: 'Morning check-in. Anything you want to bring to today?',
    created_at: '2026-10-06T06:30:00Z',
    rhythm_provenance: { creator_name: 'Sam', title: 'Morning check-in', scheduled_for: '2026-10-06T06:30:00Z' },
  };
  const ANSWER =
    "Morning. A quiet answer today: I'm still turning over yesterday's question about the move, and I'd rather keep at it than report on it. Ask me again tonight?";
  let answer = $derived({
    id: 'r2',
    role: 'assistant',
    content: typed(ANSWER, t, 9.6, 12.6),
    streaming: t < 12.6,
    created_at: '2026-10-06T06:31:00Z',
    author_name: 'Wren',
    author_colour: 'teal',
  });
</script>

<div
  class="clip-stage relative overflow-hidden bg-muted"
  style="width: 1280px; height: 720px; font-family: Inter, ui-sans-serif, system-ui, sans-serif;">
  <div class="absolute inset-0" style="opacity: {loopFade(t, DURATION)}">
    <div
      class="absolute left-1/2 top-1/2"
      style="width: 700px; transform: translate(-50%, -50%) scale(1.2); opacity: {sceneOne}">
      <div class="mb-5 flex items-end justify-between">
        <div>
          <h1 class="text-3xl font-bold">Rhythms</h1>
          <p class="mt-1 text-muted-foreground">What you've agreed to come back to, together.</p>
        </div>
        <div
          class="flex items-center gap-1.5 rounded-full border bg-background px-3 py-1 text-sm tabular-nums shadow-sm"
          style="opacity: {ease(ramp(t, 3.4, 3.8))}; transform: scale({1 +
            tick * 0.08 -
            ease(ramp(t, 4.9, 5.2)) * 0.08})">
          <Clock size={14} /> Tue {minute}
        </div>
      </div>
      <div class="space-y-3">
        {#each rhythms as rhythm (rhythm.id)}
          <div
            class="rounded-lg"
            style="{arrive(t, rhythm.at, 20)} {rhythm.id === 1
              ? `box-shadow: 0 0 0 ${3 * glow}px rgb(20 184 166 / ${0.55 * glow})`
              : ''}">
            <RhythmCard {rhythm} accountId="a1" />
          </div>
        {/each}
      </div>
    </div>

    <div
      class="absolute left-1/2 top-1/2"
      style="width: 680px; transform: translate(-50%, -50%) scale(1.45); opacity: {sceneTwo}">
      <div class="space-y-5">
        <div style={arrive(t, 7.5)}>
          <MessageBubble message={invitation} />
        </div>
        <div style="{arrive(t, 9.2)} min-height: 150px">
          <MessageBubble message={answer} />
        </div>
      </div>
    </div>
  </div>
</div>
