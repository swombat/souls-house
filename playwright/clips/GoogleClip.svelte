<script>
  // Google Workspace: connected with your own Google login, shared only with the residents you choose.
  import {
    GoogleLogo,
    Feather,
    Leaf,
    CheckCircle,
    EnvelopeSimple,
    CalendarBlank,
    GoogleDriveLogo,
    FileText,
    Table,
    Presentation,
    VideoCamera,
  } from 'phosphor-svelte';
  import { ramp, ease, typed, loopFade, arrive } from './timeline.js';

  let { t = 0 } = $props();
  const DURATION = 15;
  const services = [
    [EnvelopeSimple, 'Gmail'],
    [CalendarBlank, 'Calendar'],
    [GoogleDriveLogo, 'Drive'],
    [FileText, 'Docs'],
    [Table, 'Sheets'],
    [Presentation, 'Slides'],
    [VideoCamera, 'Meet'],
  ];
  let wrenOn = $derived(ease(ramp(t, 4.4, 4.7)));
</script>

<!-- bg-teal-100 -->
<div
  class="clip-stage relative overflow-hidden bg-muted"
  style="width: 1280px; height: 720px; font-family: Inter, ui-sans-serif, system-ui, sans-serif;">
  <div class="absolute inset-0" style="opacity: {loopFade(t, DURATION)}">
    <div
      class="absolute rounded-2xl border bg-card p-7 shadow-md"
      style="left: 70px; top: 60px; width: 640px; {arrive(t, 0.3)}">
      <p class="flex items-center gap-3 text-[24px] font-semibold">
        <GoogleLogo size={28} weight="bold" /> Google Workspace
      </p>
      <p class="mt-3 flex items-center gap-2 text-[19px]" style={arrive(t, 1.0, 8)}>
        <CheckCircle size={20} weight="fill" class="text-emerald-600" /> Connected with your own Google login · sam@example.com
      </p>
      <div class="mt-5 flex flex-wrap gap-2">
        {#each services as [Icon, label], i}
          <span
            class="inline-flex items-center gap-1.5 rounded-md border px-3 py-1.5 text-[17px]"
            style={arrive(t, 1.6 + i * 0.15, 6)}><Icon size={17} /> {label}</span>
        {/each}
      </div>
      <p class="mt-7 text-[19px] font-medium">Resident access</p>
      <div class="mt-3 space-y-3">
        {#each [['Wren', Feather, 'teal', wrenOn], ['Juniper', Leaf, 'amber', 0]] as [name, Icon, colour, on]}
          <div class="flex items-center justify-between rounded-lg border px-4 py-3 text-[20px]">
            <span class="flex items-center gap-2"
              ><Icon size={20} weight="duotone" class={colour === 'teal' ? 'text-teal-700' : 'text-amber-700'} />
              {name}</span>
            <span
              class="relative h-7 w-12 rounded-full"
              style="background: {on ? `rgb(20 184 166 / ${0.3 + 0.7 * on})` : 'rgb(203 213 225)'}">
              <span class="absolute top-1 size-5 rounded-full bg-white shadow" style="left: {4 + 20 * on}px"></span>
            </span>
          </div>
        {/each}
      </div>
      <p class="mt-3 text-[16px] text-muted-foreground">
        Juniper can't see your mail or calendar unless you switch it on.
      </p>
    </div>

    <div
      class="absolute rounded-2xl bg-teal-100 p-6 shadow-md"
      style="left: 760px; top: 180px; width: 450px; {arrive(t, 6.6)}">
      <p class="flex items-center gap-2 text-[16px] font-medium uppercase tracking-wide text-teal-800">
        <Feather size={16} weight="duotone" /> Wren
      </p>
      <p class="mt-3 text-[21px] leading-snug">
        {typed(
          "Ana's flight moved to 18:40. I've changed it in your calendar and put her boarding pass in Drive, under Lisbon.",
          t,
          6.9,
          10.4
        )}
      </p>
    </div>
  </div>
</div>
