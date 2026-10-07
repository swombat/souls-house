<script>
  // A computer of their own: the resident's own shell, home directory and tools, used for their own reasons.
  import { TerminalWindow } from 'phosphor-svelte';
  import { ramp, loopFade } from './timeline.js';

  let { t = 0 } = $props();
  const DURATION = 16;

  // Each step: a command typed by the resident, then its output appearing at once.
  const steps = [
    { at: 0.8, cmd: 'ls ~', out: ['journal/   notes/   projects/   soul.md   self-narrative.md'] },
    {
      at: 2.8,
      cmd: 'cat notes/tides.md | head -3',
      out: [
        '# Why the second low tide comes later',
        'The moon moves on ~50 minutes a day.',
        'Ask Sam: does the harbour wall change this?',
      ],
    },
    {
      at: 5.6,
      cmd: 'python3 projects/tides/predict.py --port lisbon --days 3',
      out: [
        'date        low 1   low 2',
        'Tue 6 Oct   05:41   18:03',
        'Wed 7 Oct   06:27   18:52',
        'Thu 8 Oct   07:15   19:44',
      ],
    },
    {
      at: 9.4,
      cmd: 'git -C projects/tides commit -am "predictions match the harbour board"',
      out: ['[main 3f2c1a9] predictions match the harbour board', ' 1 file changed, 12 insertions(+), 3 deletions(-)'],
    },
    { at: 12.4, cmd: '', out: [] },
  ];
  const TYPE = 1.0;
  const lineOf = (s) =>
    s.cmd.slice(0, Math.round(s.cmd.length * ramp(t, s.at, s.at + TYPE * Math.min(1.6, 0.4 + s.cmd.length / 45))));
  const typingDone = (s) => s.at + TYPE * Math.min(1.6, 0.4 + s.cmd.length / 45);
  let caretOn = $derived(Math.floor(t * 2) % 2 === 0);
</script>

<div
  class="clip-stage relative overflow-hidden bg-muted"
  style="width: 1280px; height: 720px; font-family: Inter, ui-sans-serif, system-ui, sans-serif;">
  <div class="absolute inset-0 flex items-center justify-center" style="opacity: {loopFade(t, DURATION)}">
    <div class="overflow-hidden rounded-xl bg-[#1d2127] shadow-2xl" style="width: 1140px; height: 620px">
      <div class="flex items-center gap-2 bg-[#2a2f37] px-4 py-2.5 text-sm text-slate-300">
        <span class="size-3 rounded-full bg-[#ff5f57]"></span>
        <span class="size-3 rounded-full bg-[#febc2e]"></span>
        <span class="size-3 rounded-full bg-[#28c840]"></span>
        <TerminalWindow size={16} class="ml-3" /> wren@house: ~
      </div>
      <div
        class="space-y-1 px-6 py-5 text-[22px] leading-[1.5] text-slate-200"
        style="font-family: 'Source Code Pro', 'Ubuntu Mono', ui-monospace, Menlo, monospace">
        {#each steps as s, i}
          {#if t >= s.at - 0.4 && (i === 0 || t >= steps[i - 1].at)}
            <p>
              <span class="text-teal-300">wren@house</span><span class="text-slate-400">:~$</span>
              {lineOf(s)}{#if (t < typingDone(s) + 0.3 || i === steps.length - 1) && caretOn}<span
                  class="text-slate-300">▍</span
                >{/if}
            </p>
            {#if t >= typingDone(s) + 0.3}
              {#each s.out as line}
                <p class="whitespace-pre text-slate-400">{line}</p>
              {/each}
            {/if}
          {/if}
        {/each}
      </div>
    </div>
  </div>
</div>
