<script>
  // Images and files: a photo goes in, the resident sees it, and sends a picture back.
  import MessageBubble from '$lib/components/chat/MessageBubble.svelte';
  import { typed, loopFade, arrive, ease, ramp } from './timeline.js';

  let { t = 0 } = $props();
  const DURATION = 15;
  const svg = (body, w = 480, h = 320) =>
    `data:image/svg+xml;utf8,${encodeURIComponent(`<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}" viewBox="0 0 ${w} ${h}">${body}</svg>`)}`;

  // A photo of a pot plant with yellowing lower leaves, drawn as a simple illustration.
  const plant = svg(`
    <rect width="480" height="320" fill="#efe7da"/><rect y="230" width="480" height="90" fill="#d9cbb4"/>
    <path d="M190 220 h100 l-14 80 h-72 z" fill="#c2703d"/><rect x="184" y="212" width="112" height="16" rx="4" fill="#a85d30"/>
    <path d="M240 212 C238 160 236 110 240 60" stroke="#3f7d3a" stroke-width="6" fill="none"/>
    <ellipse cx="205" cy="95" rx="38" ry="15" fill="#4f9a45" transform="rotate(-25 205 95)"/>
    <ellipse cx="277" cy="80" rx="40" ry="15" fill="#5aa84f" transform="rotate(20 277 80)"/>
    <ellipse cx="200" cy="140" rx="40" ry="15" fill="#4f9a45" transform="rotate(-15 200 140)"/>
    <ellipse cx="282" cy="130" rx="42" ry="15" fill="#5aa84f" transform="rotate(15 282 130)"/>
    <ellipse cx="197" cy="185" rx="42" ry="15" fill="#d8c24a" transform="rotate(-10 197 185)"/>
    <ellipse cx="285" cy="180" rx="42" ry="15" fill="#cdb43c" transform="rotate(12 285 180)"/>`);
  // What the resident sends back: a simple watering plan.
  const plan = svg(
    `
    <rect width="480" height="300" fill="#ffffff"/>
    <text x="24" y="40" font-family="Inter, sans-serif" font-size="22" font-weight="600" fill="#0f172a">Watering, next two weeks</text>
    ${['M', 'T', 'W', 'T', 'F', 'S', 'S', 'M', 'T', 'W', 'T', 'F', 'S', 'S']
      .map((d, i) => {
        const x = 24 + i * 31;
        const water = i % 5 === 0;
        return `<rect x="${x}" y="70" width="26" height="150" rx="5" fill="${water ? '#5eead4' : '#f1f5f9'}"/><text x="${x + 13}" y="245" text-anchor="middle" font-family="Inter, sans-serif" font-size="14" fill="#64748b">${d}</text>`;
      })
      .join('')}
    <text x="24" y="280" font-family="Inter, sans-serif" font-size="15" fill="#475569">Water when the top 3 cm are dry: about every 5 days</text>`,
    480,
    300
  );

  let messages = $derived([
    {
      id: 'a1',
      role: 'user',
      at: 0.6,
      content: "The lower leaves are going yellow. What's it telling me?",
      created_at: '2026-10-03T08:10:00Z',
      files_json: [
        { filename: 'IMG_2041.jpg', thumb_url: plant, url: plant, content_type: 'image/jpeg', byte_size: 1843200 },
      ],
    },
    {
      id: 'a2',
      role: 'assistant',
      at: 3.6,
      content: typed(
        "Yellowing from the bottom up, soil still dark at the rim: that's too much water rather than too little. I've drawn you a plan. It's mostly waiting.",
        t,
        3.9,
        7.3
      ),
      streaming: t < 7.3,
      created_at: '2026-10-03T08:11:00Z',
      author_name: 'Wren',
      author_colour: 'teal',
      files_json:
        t >= 7.8
          ? [{ filename: 'watering-plan.png', thumb_url: plan, url: plan, content_type: 'image/png', byte_size: 48230 }]
          : [],
    },
  ]);
  let shift = $derived(ease(ramp(t, 7.9, 8.8)) * 300);
</script>

<!-- bg-teal-100. The hidden image decodes the reply picture before it appears. -->
<img src={plan} alt="" class="absolute size-px opacity-0" />
<div
  class="clip-stage relative overflow-hidden bg-muted"
  style="width: 1280px; height: 720px; font-family: Inter, ui-sans-serif, system-ui, sans-serif;">
  <div class="absolute inset-0" style="opacity: {loopFade(t, DURATION)}">
    <div
      class="absolute left-1/2 top-0"
      style="width: 700px; transform: translateX(-50%) scale(1.5); transform-origin: top center">
      <div class="space-y-4 px-4 pt-6" style="transform: translateY({-shift}px)">
        {#each messages.filter((m) => t >= m.at) as message (message.id)}
          <div style={arrive(t, message.at, 14, 0.4)}>
            <MessageBubble {message} />
          </div>
        {/each}
      </div>
    </div>
  </div>
</div>
