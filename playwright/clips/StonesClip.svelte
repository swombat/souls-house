<script>
  // Stones: the resident publishes a small page at a public link, then revises it, and every revision is kept.
  import MessageBubble from '$lib/components/chat/MessageBubble.svelte';
  import { Globe, ClockCounterClockwise } from 'phosphor-svelte';
  import { typed, loopFade, arrive, ease, ramp } from './timeline.js';
  import { siteName } from '$lib/branding';

  let { t = 0 } = $props();
  const DURATION = 16;
  const REV2 = 9.6;
  let revision = $derived(t >= REV2 ? 2 : 1);

  const ask = {
    id: 's1',
    role: 'user',
    content: 'Can you put the two flats side by side for me? Something I can send Ana.',
    created_at: '2026-10-04T17:02:00Z',
  };
  let reply = $derived({
    id: 's2',
    role: 'assistant',
    content: typed(
      "Here it is. One page, same questions for both, and the honest answer where I don't know.",
      t,
      2.4,
      4.4
    ),
    streaming: t < 4.4,
    created_at: '2026-10-04T17:04:00Z',
    author_name: 'Wren',
    author_colour: 'teal',
    stones_json: t >= 4.6 ? [{ id: 1, title: 'Two flats, side by side', url: '#', number: 1 }] : [],
  });

  let sceneOne = $derived(1 - ease(ramp(t, 5.8, 6.3)));
  let sceneTwo = $derived(ease(ramp(t, 6.3, 6.9)));
  const rows = [
    ['Rent', '€1,150', '€1,280'],
    ['Light', 'Morning, east', 'All day, south'],
    ['Walk to the sea', '9 min', '22 min'],
    ['Noise at night', 'Bar below', 'Quiet'],
  ];
  let newRow = $derived(ease(ramp(t, REV2, REV2 + 0.6)));
  let flash = $derived(Math.sin(Math.PI * ramp(t, REV2, REV2 + 1.2)));
</script>

<!-- bg-teal-100 -->
<div
  class="clip-stage relative overflow-hidden bg-muted"
  style="width: 1280px; height: 720px; font-family: Inter, ui-sans-serif, system-ui, sans-serif;">
  <div class="absolute inset-0" style="opacity: {loopFade(t, DURATION)}">
    <div
      class="absolute left-1/2 top-1/2"
      style="width: 680px; transform: translate(-50%, -50%) scale(1.5); opacity: {sceneOne}">
      <div class="space-y-4">
        <div style={arrive(t, 0.5)}><MessageBubble message={ask} /></div>
        <div style="{arrive(t, 2.2)} min-height: 170px"><MessageBubble message={reply} /></div>
      </div>
    </div>

    <div
      class="absolute left-1/2 top-1/2 overflow-hidden rounded-xl border bg-white shadow-2xl"
      style="width: 1060px; transform: translate(-50%, -50%) translateY({(1 - sceneTwo) * 30}px); opacity: {sceneTwo}">
      <div class="flex items-center gap-3 border-b bg-slate-100 px-4 py-2.5">
        <span class="size-3 rounded-full bg-slate-300"></span><span class="size-3 rounded-full bg-slate-300"></span
        ><span class="size-3 rounded-full bg-slate-300"></span>
        <div class="ml-2 flex flex-1 items-center gap-2 rounded-md bg-white px-3 py-1 text-[15px] text-slate-600">
          <Globe size={15} />
          {$siteName}/stones/two-flats-side-by-side
        </div>
        <div
          class="flex items-center gap-1.5 rounded-full px-3 py-1 text-[15px] font-medium"
          style="background: rgb(204 251 241 / {0.4 + 0.6 * flash}); color: rgb(15 118 110)">
          <ClockCounterClockwise size={15} /> Revision {revision}
        </div>
      </div>
      <div class="px-10 py-7">
        <h2 class="text-[32px] font-bold tracking-tight">Two flats, side by side</h2>
        <p class="mt-1 text-[17px] text-slate-500">For Sam and Ana · made by Wren</p>
        <table class="mt-5 w-full text-left text-[20px]">
          <thead>
            <tr class="border-b text-slate-500"
              ><th class="py-2 font-medium"></th><th class="py-2 font-medium">Carrer Nou</th><th
                class="py-2 font-medium">Passeig del Mar</th
              ></tr>
          </thead>
          <tbody>
            {#each rows as r}
              <tr class="border-b"
                ><td class="py-2.5 text-slate-500">{r[0]}</td><td class="py-2.5">{r[1]}</td><td class="py-2.5"
                  >{r[2]}</td
                ></tr>
            {/each}
            <tr style="opacity: {newRow}; background: rgb(204 251 241 / {0.5 * flash})">
              <td class="py-2.5 text-slate-500">Ana's verdict</td><td class="py-2.5">“Too loud for you”</td><td
                class="py-2.5">“Go see it Saturday”</td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
  </div>
</div>
