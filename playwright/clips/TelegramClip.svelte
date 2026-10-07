<script>
  // Telegram: connect a bot with the real settings panel, then the resident writes first and hears a voice note.
  import { writable } from 'svelte/store';
  import { Card, CardContent } from '$lib/components/shadcn/card';
  import TelegramSettings from '$lib/components/agents/telegram-settings.svelte';
  import { TelegramLogo, Play, Microphone, Checks } from 'phosphor-svelte';
  import { ramp, ease, lerp, typed, loopFade, arrive } from './timeline.js';

  let { t = 0 } = $props();
  const DURATION = 16;

  const form = writable({ agent: { telegram_bot_username: '', telegram_bot_token: '' }, errors: {} });
  let username = $derived(typed('wren_at_home_bot', t, 1.2, 2.4));
  let token = $derived(typed('7351904826:AAH3kq9ZxWc0mVb8LrT1yNfDe4pQs6uJ2oI', t, 2.7, 3.6));
  let configured = $derived(t >= 4.4);
  $effect(() => {
    form.set({ agent: { telegram_bot_username: username, telegram_bot_token: configured ? '' : token }, errors: {} });
  });
  let agent = $derived({ name: 'Wren', telegram_configured: configured, telegram_bot_username: 'wren_at_home_bot' });

  // Camera: on the inputs while typing, then up to the connected banner.
  let rise = $derived(ease(ramp(t, 4.4, 4.45)));
  let focusY = $derived(configured ? lerp(470, 175, rise) : 470);
  const zoom = 1.45;
  // A short dip hides the layout change when the panel switches to its connected state.
  let dip = $derived(1 - Math.sin(Math.PI * ramp(t, 4.2, 4.6)) * 0.85);
  let sceneOne = $derived(1 - ease(ramp(t, 6.4, 6.8)));
  let sceneTwo = $derived(ease(ramp(t, 6.9, 7.4)));
</script>

<div
  class="clip-stage relative overflow-hidden bg-muted"
  style="width: 1280px; height: 720px; font-family: Inter, ui-sans-serif, system-ui, sans-serif;">
  <div class="absolute inset-0" style="opacity: {loopFade(t, DURATION)}">
    <div
      class="absolute left-0 top-0"
      style="width: 640px; transform-origin: 0 0; opacity: {sceneOne * dip};
        transform: translate({640 - 320 * zoom}px, {360 - focusY * zoom}px) scale({zoom})">
      <Card class="shadow-lg">
        <CardContent class="p-6">
          <TelegramSettings
            {form}
            {agent}
            telegramDeepLink="https://t.me/wren_at_home_bot?start=k2Jx81"
            telegramSubscriberCount={0}
            showIntegrationList={() => {}} />
        </CardContent>
      </Card>
    </div>

    <div class="absolute inset-0 flex items-center justify-center" style="opacity: {sceneTwo}">
      <div
        class="overflow-hidden rounded-2xl border bg-[#e6ebee] shadow-lg"
        style="width: 600px; transform: scale(1.6)">
        <div class="flex items-center gap-3 border-b bg-white px-5 py-3">
          <div class="flex size-9 items-center justify-center rounded-full bg-teal-500 text-white">
            <TelegramLogo size={20} weight="fill" />
          </div>
          <div>
            <p class="text-sm font-semibold">Wren</p>
            <p class="text-xs text-sky-600">bot</p>
          </div>
        </div>
        <div class="flex h-[330px] flex-col justify-end gap-3 px-5 py-5 text-[15px] leading-snug">
          <div
            class="max-w-[78%] self-start rounded-2xl rounded-bl-sm bg-white px-4 py-2.5 shadow-sm"
            style={arrive(t, 7.6)}>
            Morning. I read the tide-table piece you sent last night. I've got a question for when you're up.
            <span class="ml-2 text-[11px] text-muted-foreground">07:58</span>
          </div>
          <div
            class="max-w-[60%] self-end rounded-2xl rounded-br-sm bg-[#dcf7c5] px-4 py-2.5 shadow-sm"
            style={arrive(t, 9.4)}>
            <div class="flex items-center gap-3">
              <div class="flex size-9 items-center justify-center rounded-full bg-emerald-500 text-white">
                <Play size={16} weight="fill" />
              </div>
              <div class="flex h-6 items-end gap-[3px]">
                {#each [6, 12, 18, 9, 22, 14, 7, 16, 20, 11, 6, 13, 19, 8, 15, 10, 5, 12] as h}
                  <span class="w-[3px] rounded bg-emerald-600/70" style="height: {h}px"></span>
                {/each}
              </div>
              <span class="text-xs text-emerald-800">0:06</span>
            </div>
            <p
              class="mt-2 border-t border-emerald-700/15 pt-2 text-sm italic text-emerald-950"
              style={arrive(t, 10.5, 6)}>
              <Microphone size={12} class="mr-1 inline" />
              “{typed('Up now. Go on, ask.', t, 10.6, 11.3)}”
            </p>
            <div class="mt-1 flex justify-end text-emerald-700"><Checks size={14} /></div>
          </div>
          <div
            class="max-w-[78%] self-start rounded-2xl rounded-bl-sm bg-white px-4 py-2.5 shadow-sm"
            style={arrive(t, 12.3)}>
            {typed(
              'Why does the second low tide come later each day? I think I know, but I want to hear you explain it.',
              t,
              12.4,
              13.9
            )}
            <span class="ml-2 text-[11px] text-muted-foreground">08:04</span>
          </div>
        </div>
      </div>
    </div>
  </div>
</div>
