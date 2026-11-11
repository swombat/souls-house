<script>
  // Draws the six resident "dots" from the pitch film (cast/residents.js on cast/engine.js) onto a canvas
  // overlay. Pure function of `t`. Each member of `beings`:
  //   { who: 'chris'|'claude'|'grok'|'lume'|'mira'|'wing', x, y, r, look:[-1..1,-1..1], mood, blink,
  //     squash, alpha, energy }
  // x, y, r are in this canvas's own pixels (width x height, default 1280 x 720). The foot sits at about y + r.
  // A plain FILM.being (no motif) can be drawn with who: 'being' and a colour.
  import './engine.js';
  import './residents.js';

  let { t = 0, beings = [], width = 1280, height = 720, style = '' } = $props();
  let canvas = $state();

  $effect(() => {
    const list = beings;
    const T = t;
    if (!canvas) return;
    const ctx = canvas.getContext('2d');
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, width, height);
    for (const b of list) {
      if (!b || (b.alpha !== undefined && b.alpha <= 0.01)) continue;
      const o = Object.assign({ T }, b);
      if (b.who === 'being') window.FILM.being(ctx, o);
      else window.RESIDENTS[b.who](ctx, o);
      window.FILM.plain(ctx);
    }
  });
</script>

<canvas
  bind:this={canvas}
  {width}
  {height}
  style="position:absolute;inset:0;width:100%;height:100%;pointer-events:none;{style}"></canvas>
