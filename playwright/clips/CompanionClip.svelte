<script>
  // Left: the companion's menu bar dropdown, drawn (there is no house component for it); its strings are the ones in
  // menubar/Sources/SoulsHouseMenu/main.swift. Right: the REAL Computers page (accounts/computers.svelte) mounted with
  // fixtures: one Mac, two residents, one card (a single computer starts open, as in the page).
  import { page } from '@inertiajs/svelte';
  import Computers from '../../app/frontend/pages/accounts/computers.svelte';
  import Cast from './cast/Cast.svelte';
  import { ramp, ease, lerp, arrive } from './timeline.js';

  let { t = 0 } = $props();
  const DURATION = 14;
  const SCALE = 1.3;
  const PANE_X = 600; // right pane starts here
  const CAP_H = 84;

  page.set({
    props: { site_settings: { site_name: 'the house' }, flash: {} },
    component: 'accounts/computers',
    url: '/accounts/acct/computers',
    version: 'test',
  });

  const ago = (ms) => new Date(Date.now() - ms).toISOString();
  const week = (counts) => {
    const now = new Date();
    return counts.map((jobs, i) => {
      const d = new Date(now.getTime() - (6 - i) * 86400000);
      return { date: d.toISOString().slice(0, 10), jobs };
    });
  };
  const account = { id: 'acct', name: 'Home' };
  const A = 'darwin-volume:ab12cd34ef';
  const B = 'darwin-volume:5e6f7a8b9c';
  const devices = [
    {
      id: 'd1',
      name: 'Studio Mac',
      paused: false,
      connected: true,
      enrolled_at: '2026-11-04T09:00:00Z',
      activity: { days: week([2, 4, 1, 5, 3, 6, 4]), failed: 0, last_job_at: ago(9 * 60000) },
      ceiling: {
        reported_at: '2026-11-11T09:40:00Z',
        current: true,
        residents: {
          lume: [
            { volume: A, access: 'write' },
            { volume: B, access: 'read' },
          ],
          mira: [{ volume: A, access: 'read' }],
        },
      },
      residents: [
        {
          id: 'lume',
          name: 'Lume',
          execute: false,
          desktop: true,
          volumes: [
            { volume: A, access: 'write' },
            { volume: B, access: 'read' },
          ],
        },
        { id: 'mira', name: 'Mira', execute: false, desktop: false, volumes: [{ volume: A, access: 'read' }] },
      ],
    },
  ];
  const warnings = { execute: 'Run commands.', desktop: 'Use apps.', write: 'Write.' };

  const CAPTIONS = [
    [0, 'Residents work in the folders you choose.'],
    [5, 'A switch in the menu bar lets them use your apps, for 15 minutes.'],
    [13.7, 'Residents work in the folders you choose.'],
  ];
  const caption = $derived([...CAPTIONS].reverse().find(([at]) => t >= at));
  const capIdx = $derived(CAPTIONS.findIndex((c) => c === caption));

  // Timeline of the drawn menu. The last stretch (flip at 13.65, under a dip to white) returns to the frame-0 state.
  const CLICK = 7.7;
  const on = $derived(t >= CLICK + 0.15 && t < 13.65);
  const shown = $derived(t < 13.65 ? t : 0);
  const P0 = { x: 585, y: 440 }; // pointer rest, just outside the menu
  const MENU_TOP = 150;
  const ROW = 40;
  const target = { x: 430, y: MENU_TOP + 10 + ROW + ROW / 2 }; // "Turn on for 15 minutes" (row 2)
  const toTarget = $derived(ease(ramp(t, 5.6, 6.9)));
  const toBack = $derived(ease(ramp(t, 12.4, 13.4)));
  const pm = $derived(toTarget * (1 - toBack));
  const pointer = $derived({ x: lerp(P0.x, target.x, pm), y: lerp(P0.y, target.y, pm) });
  const hover = $derived(!on && toTarget >= 1 && toBack === 0);
  const pressed = $derived(t >= CLICK && t < CLICK + 0.15);

  const clock = '10:30';
  const until = '10:45'; // 10:30 + 15 minutes

  let host = $state();
  let scrollTop = $state(0);
  $effect(() => {
    void t;
    if (!host) return;
    const card = host.querySelector('[data-testid=computer]');
    if (card) scrollTop = (card.getBoundingClientRect().top - host.getBoundingClientRect().top) / SCALE - 12;
  });
  const scroll = $derived(scrollTop + ease(ramp(t, 0.8, 3.6)) * 150 * (t >= 13.65 ? 0 : 1));

  const dip = $derived(ramp(t, 13.3, 13.65) * (1 - ramp(t, 13.65, 14)));
  const hop = (at) => Math.max(0, Math.sin(Math.PI * ramp(t, at, at + 0.55))) * 30;
  const blink = (k) => Math.max(0, Math.sin(t * 3.1 + k) - 0.97) * 30;
  const beings = $derived([
    {
      who: 'lume',
      x: 82,
      y: 392 - hop(CLICK + 0.45),
      r: 46,
      look: [on ? 0.7 : 0.7, -0.6],
      mood: on ? 'happy' : 'calm',
      blink: blink(0),
      squash: 0,
      energy: on ? 0.9 : 0.5,
    },
    { who: 'mira', x: 82, y: 560, r: 40, look: [0.7, -0.5], mood: 'calm', blink: blink(2), squash: 0, energy: 0.4 },
  ]);
</script>

<div
  class="clip-stage"
  style="position:relative;width:1280px;height:720px;background:#fff;overflow:hidden;font-family:Inter,ui-sans-serif,system-ui,sans-serif;">
  <div
    style="position:absolute;left:0;right:0;top:0;height:{CAP_H}px;display:flex;align-items:center;padding:0 36px;font-size:30px;font-weight:600;color:#1c1917;background:#fff;z-index:5;border-bottom:1px solid #e7e5e4;">
    {#key capIdx}
      <span style={capIdx === 1 ? arrive(t, caption[0], 10, 0.4) : ''}>{caption[1]}</span>
    {/key}
  </div>

  <!-- Left: a Mac's menu bar and the companion's dropdown -->
  <div
    style="position:absolute;left:0;top:{CAP_H}px;width:{PANE_X}px;bottom:0;background:#f4f4f5;border-right:1px solid #e7e5e4;">
    <div
      style="position:absolute;left:0;right:0;top:0;height:44px;background:#e4e4e7;display:flex;align-items:center;justify-content:flex-end;gap:22px;padding:0 20px;font-size:20px;color:#27272a;font-weight:500;">
      <svg width="42" height="36" viewBox="0 0 240 210">
        <path
          d="M16 100 L120 24 L224 100"
          fill="none"
          stroke="#27272a"
          stroke-width="26"
          stroke-linecap="round"
          stroke-linejoin="round" />
        {#if on}
          <circle cx="120" cy="148" r="58" fill="#f15d61" />
        {:else}
          <circle cx="120" cy="148" r="47" fill="none" stroke="#f15d61" stroke-width="22" />
        {/if}
      </svg>
      <span>{clock}</span>
    </div>

    <div
      style="position:absolute;left:150px;top:{MENU_TOP -
        CAP_H}px;width:420px;padding:10px 0;border-radius:14px;background:rgba(255,255,255,0.97);box-shadow:0 14px 40px rgba(0,0,0,0.22),0 0 0 1px rgba(0,0,0,0.12);font-size:20px;color:#18181b;font-family:-apple-system,'SF Pro Text',Inter,system-ui,sans-serif;">
      {@render dis(on ? `Desktop control: on until ${until}` : 'Desktop control: off')}
      {#if on}
        {@render act('Turn off', false)}
      {:else}
        {@render act('Turn on for 15 minutes', hover)}
        {@render act('Turn on for 1 hour', false)}
        {@render act('Turn on until I turn it off', false)}
      {/if}
      {@render sep()}
      {@render dis('Accessibility: granted')}
      {@render sep()}
      {@render act('Pause companion', false)}
      {@render sep()}
      {@render act('Quit menu', false)}
    </div>

    <div
      style="position:absolute;left:{pointer.x - 0}px;top:{pointer.y - CAP_H}px;z-index:6;transform:scale({pressed
        ? 0.88
        : 1});transform-origin:3px 2px;pointer-events:none;">
      <svg width="30" height="38" viewBox="0 0 30 38"
        ><path
          d="M3 2 L3 28 L10 22 L15 33 L20 31 L15 20.5 L24 20 Z"
          fill="#111"
          stroke="#fff"
          stroke-width="2"
          stroke-linejoin="round" /></svg>
    </div>
  </div>

  <!-- Right: the real Computers page -->
  <div style="position:absolute;left:{PANE_X}px;top:{CAP_H}px;width:{1280 - PANE_X}px;bottom:0;overflow:hidden;">
    <div
      style="width:{(1280 - PANE_X) / SCALE}px;height:{(720 - CAP_H) /
        SCALE}px;transform:scale({SCALE});transform-origin:0 0;overflow:hidden;">
      <div
        bind:this={host}
        class="cc-host bg-background text-foreground"
        style="width:100%;transform:translateY({-scroll}px);">
        <Computers {account} {devices} can_manage={true} {warnings} />
      </div>
    </div>
  </div>

  <Cast {t} {beings} />
  <div style="position:absolute;inset:0;background:#fff;opacity:{dip};z-index:9;pointer-events:none;"></div>
</div>

{#snippet dis(label)}
  <div style="height:{ROW}px;display:flex;align-items:center;padding:0 22px;color:#71717a;">{label}</div>
{/snippet}
{#snippet act(label, hl)}
  <div
    style="height:{ROW}px;display:flex;align-items:center;margin:0 8px;padding:0 14px;border-radius:8px;{hl
      ? 'background:#0a64d8;color:#fff;'
      : ''}">
    {label}
  </div>
{/snippet}
{#snippet sep()}
  <div style="height:1px;background:#e4e4e7;margin:6px 14px;"></div>
{/snippet}

<style>
  /* The page's tab rail is hidden: it is not what this clip is about, and the pane is narrow. */
  :global(.cc-host nav[aria-label='Account settings']) {
    display: none;
  }
  :global(.cc-host .p-8) {
    padding: 14px;
  }
</style>
