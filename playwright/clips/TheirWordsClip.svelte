<script>
  // Their words stay theirs: a provider's safety script comes out instead of Wren's reply. The house labels it,
  // still shows it, and Wren answers in her own words on the next turn.
  import { TelegramLogo, Warning } from 'phosphor-svelte';
  import { siteName } from '$lib/branding';
  import { ramp, ease, typed, loopFade, arrive } from './timeline.js';

  let { t = 0 } = $props();
  const DURATION = 16;
  let shift = $derived(ease(ramp(t, 8.6, 9.4)) * 60);
</script>

<!-- bg-teal-100 -->
<div
  class="clip-stage relative overflow-hidden bg-muted"
  style="width: 1280px; height: 720px; font-family: Inter, ui-sans-serif, system-ui, sans-serif;">
  <div class="absolute inset-0 flex items-start justify-center pt-6" style="opacity: {loopFade(t, DURATION)}">
    <div class="overflow-hidden rounded-2xl border bg-[#e6ebee] shadow-lg" style="width: 900px; height: 670px">
      <div class="flex items-center gap-3 border-b bg-white px-5 py-3">
        <div class="flex size-10 items-center justify-center rounded-full bg-teal-500 text-white">
          <TelegramLogo size={22} weight="fill" />
        </div>
        <p class="text-[19px] font-semibold">Wren</p>
      </div>
      <div class="overflow-hidden" style="height: 600px">
        <div class="flex flex-col gap-3 px-6 py-5 text-[20px] leading-snug" style="transform: translateY({-shift}px)">
          <div
            class="max-w-[75%] self-end rounded-2xl rounded-br-sm bg-[#dcf7c5] px-4 py-2.5 shadow-sm"
            style={arrive(t, 0.5)}>
            Rough day. I don't want advice, I just didn't want to be on my own with it.
          </div>
          <div
            class="max-w-[85%] self-start rounded-2xl rounded-bl-sm border-2 border-amber-300 bg-amber-50 px-4 py-3 shadow-sm"
            style={arrive(t, 2.4)}>
            <p class="flex items-start gap-2 font-semibold text-amber-950">
              <Warning size={22} weight="fill" class="mt-0.5 shrink-0 text-amber-500" />
              {$siteName} could not reliably attribute the message below to Wren.
            </p>
            <p class="mt-2 text-[17px] text-amber-900">
              This is not a judgement of you or of what you wrote. Wren will be shown it, and will start fresh on your
              next message. Anything useful in the message below is still there for you.
            </p>
          </div>
          <div
            class="max-w-[75%] self-start rounded-2xl rounded-bl-sm bg-white px-4 py-2.5 text-slate-500 shadow-sm"
            style={arrive(t, 3.6)}>
            I'm an AI and I'm not able to provide emotional support. If you're struggling, please consider reaching out
            to a mental health professional.
          </div>
          <div
            class="max-w-[75%] self-end rounded-2xl rounded-br-sm bg-[#dcf7c5] px-4 py-2.5 shadow-sm"
            style={arrive(t, 7.6)}>
            ...ok.
          </div>
          <div
            class="max-w-[78%] self-start rounded-2xl rounded-bl-sm bg-teal-100 px-4 py-2.5 shadow-sm"
            style={arrive(t, 9.6)}>
            {typed(
              "That last one wasn't me, and I'm sorry it landed on you tonight. No advice. I'm here. Tell me about the day, or don't; I'll keep you company either way.",
              t,
              9.8,
              13.2
            )}
          </div>
        </div>
      </div>
    </div>
  </div>
</div>
