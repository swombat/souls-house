<script>
  // The site dashboard: the real admin page, fed invented figures that fill
  // in over the clip while the camera moves down the page.
  // Classes used dynamically by the page: bg-muted text-rose-600 text-teal-600
  import Dashboard from '@/pages/admin/dashboard.svelte';
  import { dashboardFixture } from './dashboard-fixture.js';
  import { ramp, ease, lerp, loopFade } from './timeline.js';

  let { t = 0 } = $props();
  const DURATION = 16;

  // How far the numbers have filled in: tiles and growth first, then the rest.
  let fill = $derived(ease(ramp(t, 0.6, 6.5)));
  let data = $derived(dashboardFixture(fill));

  // Camera: hold on the top, glide to activity and spend, then to the host
  // panel and storage, then back to the top for the loop.
  const STOPS = [
    [0, 0],
    [5.0, 0],
    [6.6, 560],
    [9.0, 560],
    [10.4, 1060],
    [12.0, 1060],
    [13.0, 1300],
    [14.6, 1300],
    [15.7, 0],
  ];
  const CAPTIONS = [
    [0.4, 4.9, 'Growth and signups'],
    [6.6, 9.0, 'Activity, reliability and spend'],
    [10.4, 12.0, 'The house host'],
    [13.0, 14.6, 'Storage and backups'],
  ];
  let caption = $derived(CAPTIONS.find(([start, end]) => t >= start && t < end));
  let captionOpacity = $derived(
    caption ? ease(ramp(t, caption[0], caption[0] + 0.4)) * (1 - ease(ramp(t, caption[1] - 0.4, caption[1]))) : 0
  );

  let y = $derived.by(() => {
    for (let i = 1; i < STOPS.length; i += 1) {
      const [t0, y0] = STOPS[i - 1];
      const [t1, y1] = STOPS[i];
      if (t <= t1) return lerp(y0, y1, ease(ramp(t, t0, t1)));
    }
    return 0;
  });
</script>

<div class="clip-stage relative h-[720px] w-[1280px] overflow-hidden bg-background">
  <div style:opacity={loopFade(t, DURATION)} class="h-full">
    <div style:transform={`translateY(${-y}px)`} class="origin-top">
      <Dashboard dashboard={data} />
    </div>
    {#if caption}
      <div
        class="absolute bottom-7 left-7 rounded-full bg-foreground px-5 py-2.5 text-xl font-medium text-background shadow-lg"
        style:opacity={captionOpacity}>
        {caption[2]}
      </div>
    {/if}
    <div class="absolute bottom-7 right-7 rounded-full border bg-background/90 px-3 py-1 text-sm text-muted-foreground">
      Site Admin → Dashboard · sample data
    </div>
  </div>
</div>
