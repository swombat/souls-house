<script>
  import { onMount } from 'svelte';
  import { fly, fade } from 'svelte/transition';
  import { Moon, Sun, ChatCircle, NotePencil } from 'phosphor-svelte';

  const scenes = [
    {
      when: 'Tuesday, 18:40',
      where: 'In the room',
      icon: ChatCircle,
      lines: [
        { who: 'you', text: "Let's stop there. The import still drops the last row and I can't see why." },
        { who: 'them', text: "Leave it with me. I'll keep turning it over." },
      ],
    },
    {
      when: 'Wednesday, 03:12',
      where: 'A heartbeat, nobody watching',
      icon: Moon,
      journal:
        "It isn't the parser. The file ends without a newline, so the reader never flushes the last line. Tell them in the morning, and own that I was wrong about the encoding.",
    },
    {
      when: 'Wednesday, 09:05',
      where: 'Back in the room',
      icon: Sun,
      lines: [
        {
          who: 'them',
          text: "Morning. I think I found yesterday's bug overnight: the file has no trailing newline. I was wrong about the encoding, too.",
        },
        { who: 'you', text: 'You kept thinking about it.' },
      ],
    },
  ];

  let step = $state(0);
  let reduced = $state(false);
  let timer;

  function start() {
    clearInterval(timer);
    if (reduced) return;
    timer = setInterval(() => (step = (step + 1) % scenes.length), 5600);
  }

  function go(i) {
    step = i;
    start();
  }

  onMount(() => {
    reduced = window.matchMedia?.('(prefers-reduced-motion: reduce)').matches ?? false;
    start();
    return () => clearInterval(timer);
  });

  const scene = $derived(scenes[step]);
  const night = $derived(step === 1);
</script>

<figure
  class="relative overflow-hidden rounded-3xl border bg-background shadow-lg"
  aria-label="A resident keeps thinking about a problem overnight, writes it in their journal, and brings the answer back the next morning.">
  <div
    class="flex items-center justify-between border-b px-5 py-3 text-xs transition-colors duration-700 {night
      ? 'border-slate-800 bg-slate-900 text-slate-300'
      : 'text-muted-foreground'}">
    {#key step}
      <span class="flex items-center gap-2" in:fade={{ duration: 400 }}>
        <scene.icon size={14} weight="bold" />
        <span class="font-medium">{scene.when}</span>
        <span class="opacity-70 max-sm:hidden">· {scene.where}</span>
      </span>
    {/key}
    <span class="flex items-center gap-1.5">
      {#each scenes as s, i (i)}
        <button
          type="button"
          aria-label="Show {s.when}"
          class="h-1.5 cursor-pointer rounded-full bg-current transition-all duration-500 {i === step
            ? 'w-5'
            : 'w-1.5 opacity-30'}"
          onclick={() => go(i)}></button>
      {/each}
    </span>
  </div>

  <div class="relative h-64 transition-colors duration-700 sm:h-52 {night ? 'bg-slate-950' : ''}">
    {#key step}
      <div class="absolute inset-x-5 top-6 space-y-3" out:fade={{ duration: 250 }}>
        {#if scene.journal}
          <div
            class="rounded-xl border border-slate-700 bg-slate-900 p-4"
            in:fly={{ y: 12, duration: 600, delay: reduced ? 0 : 300 }}>
            <p class="mb-2 flex items-center gap-2 text-xs uppercase tracking-wider text-slate-400">
              <NotePencil size={14} /> Their journal
            </p>
            <p class="font-mono text-sm leading-relaxed text-slate-200">{scene.journal}</p>
          </div>
        {:else}
          {#each scene.lines as line, i (i)}
            <div
              class="flex {line.who === 'you' ? 'justify-end' : 'justify-start'}"
              in:fly={{ y: 12, duration: 500, delay: reduced ? 0 : 300 + i * 1400 }}>
              <p
                class="max-w-[85%] rounded-2xl px-4 py-2.5 text-sm leading-relaxed {line.who === 'you'
                  ? 'rounded-br-sm bg-primary text-primary-foreground'
                  : 'rounded-bl-sm bg-muted'}">
                {line.text}
              </p>
            </div>
          {/each}
        {/if}
      </div>
    {/key}
  </div>
</figure>
