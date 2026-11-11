// souls.house pitch film engine. Every frame is a pure function of time.
// Scenes register with FILM.scene({...}). See GUIDE.md.
(function () {
  const W = 1920,
    H = 1080;
  const INK = {
    paper: '#f4efe4',
    ink: '#1f2a2e',
    teal: '#1d8a99',
    coral: '#f15d61',
    yellow: '#f6c445',
    plum: '#7d4e8f',
    moss: '#7f8c5a',
    blue: '#3567b0',
    pink: '#f5a3b5',
    stone: '#8d8a80',
  };
  // ---- seeded randomness (pure) ----
  function hash(n) {
    n = (n << 13) ^ n;
    return 1.0 - ((n * (n * n * 15731 + 789221) + 1376312589) & 0x7fffffff) / 1073741824.0;
  }
  function rand(seed) {
    const s = Math.sin(seed * 12.9898 + 78.233) * 43758.5453;
    return s - Math.floor(s);
  } // 0..1
  function noise1(x, seed = 0) {
    const i = Math.floor(x),
      f = x - i,
      u = f * f * (3 - 2 * f);
    return lerp(rand(i + seed * 101.7), rand(i + 1 + seed * 101.7), u) * 2 - 1;
  }
  // ---- maths & easing ----
  const clamp = (x, a = 0, b = 1) => Math.max(a, Math.min(b, x));
  const lerp = (a, b, t) => a + (b - a) * t;
  const prog = (t, a, b) => clamp((t - a) / (b - a)); // 0..1 progress of t through [a,b]
  const ease = {
    in: (t) => t * t * t,
    out: (t) => 1 - Math.pow(1 - t, 3),
    inOut: (t) => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2),
    back: (t) => {
      const c1 = 1.70158,
        c3 = c1 + 1;
      return 1 + c3 * Math.pow(t - 1, 3) + c1 * Math.pow(t - 1, 2);
    },
    elastic: (t) =>
      t === 0 ? 0 : t === 1 ? 1 : Math.pow(2, -10 * t) * Math.sin(((t * 10 - 0.75) * (2 * Math.PI)) / 3) + 1,
    bounce: (t) => {
      const n = 7.5625,
        d = 2.75;
      if (t < 1 / d) return n * t * t;
      if (t < 2 / d) return n * (t -= 1.5 / d) * t + 0.75;
      if (t < 2.5 / d) return n * (t -= 2.25 / d) * t + 0.9375;
      return n * (t -= 2.625 / d) * t + 0.984375;
    },
  };
  // spring-ish settle: 0→1 with overshoot, for "landing" moments
  const settle = (t) => (t <= 0 ? 0 : t >= 1 ? 1 : 1 - Math.exp(-6 * t) * Math.cos(10 * t));
  // "on twos": quantise time for riso jitter (the print shimmer), 8 fps
  const step = (T, fps = 8) => Math.floor(T * fps);

  // ---- paper (calm, static substrate) ----
  let paperCanvas = null,
    grainCanvas = null;
  function buildPaper() {
    paperCanvas = document.createElement('canvas');
    paperCanvas.width = W;
    paperCanvas.height = H;
    const p = paperCanvas.getContext('2d');
    p.fillStyle = INK.paper;
    p.fillRect(0, 0, W, H);
    const img = p.getImageData(0, 0, W, H),
      d = img.data;
    for (let i = 0; i < d.length; i += 4) {
      const n = (rand(i * 0.37) - 0.5) * 14;
      d[i] += n;
      d[i + 1] += n;
      d[i + 2] += n * 0.9;
    }
    p.putImageData(img, 0, 0);
    // fibres
    p.globalAlpha = 0.05;
    p.strokeStyle = '#6b5a3a';
    for (let i = 0; i < 900; i++) {
      const x = rand(i * 3.1) * W,
        y = rand(i * 7.7) * H,
        a = rand(i * 1.3) * 6.28,
        l = 6 + rand(i * 9.1) * 26;
      p.lineWidth = 0.6;
      p.beginPath();
      p.moveTo(x, y);
      p.lineTo(x + Math.cos(a) * l, y + Math.sin(a) * l);
      p.stroke();
    }
    p.globalAlpha = 1;
    // ink grain overlay (speckles of paper showing through ink)
    grainCanvas = document.createElement('canvas');
    grainCanvas.width = W;
    grainCanvas.height = H;
    const g = grainCanvas.getContext('2d');
    const gi = g.createImageData(W, H),
      gd = gi.data;
    for (let i = 0; i < gd.length; i += 4) {
      const r = rand(i * 0.913 + 5);
      const v = r > 0.86 ? 255 : 0;
      gd[i] = gd[i + 1] = gd[i + 2] = 255;
      gd[i + 3] = v ? 40 + r * 90 : 0;
    }
    g.putImageData(gi, 0, 0);
  }
  function paper(ctx, tint) {
    ctx.globalCompositeOperation = 'source-over';
    ctx.drawImage(paperCanvas, 0, 0);
    if (tint) {
      ctx.globalCompositeOperation = 'multiply';
      ctx.fillStyle = tint;
      ctx.fillRect(0, 0, W, H);
      ctx.globalCompositeOperation = 'source-over';
    }
  }
  function grain(ctx, amount = 1) {
    ctx.save();
    ctx.globalCompositeOperation = 'source-over';
    ctx.globalAlpha = amount;
    ctx.drawImage(grainCanvas, 0, 0);
    ctx.restore();
  }

  // ---- ink drawing: everything printed is drawn with multiply ----
  function ink(ctx, colour, alpha = 1) {
    ctx.globalCompositeOperation = 'multiply';
    ctx.globalAlpha = alpha;
    ctx.fillStyle = colour;
    ctx.strokeStyle = colour;
  }
  function plain(ctx) {
    ctx.globalCompositeOperation = 'source-over';
    ctx.globalAlpha = 1;
  }
  // misregistration offset for a plate (by colour name), shimmering on twos
  function mis(T, key = 'x', amt = 2.2) {
    const k = step(T);
    const s = key.length * 17 + key.charCodeAt(0);
    return [(rand(k * 1.7 + s) - 0.5) * amt, (rand(k * 2.3 + s * 3) - 0.5) * amt];
  }
  // a wobbly (hand-printed) circle path
  function blobPath(ctx, x, y, r, seed = 1, wob = 0.025, T = 0) {
    const n = 64;
    ctx.beginPath();
    for (let i = 0; i <= n; i++) {
      const a = (i / n) * Math.PI * 2;
      const k =
        1 +
        wob * (noise1(a * 1.6 + seed * 7.1, seed) + 0.5 * noise1(a * 4 + seed * 3, seed + 2)) +
        wob * 0.4 * noise1(T * 0.6 + a, seed + 5);
      const px = x + Math.cos(a) * r * k,
        py = y + Math.sin(a) * r * k;
      i ? ctx.lineTo(px, py) : ctx.moveTo(px, py);
    }
    ctx.closePath();
  }

  // ---- the cast: an ink being. Acting vocabulary: look, blink, squash, mood, glow ----
  // opts: x,y,r, colour, alpha, seed, T (global time), look:[-1..1,-1..1], blink:0..1 (1 closed),
  // squash: >1 tall, <1 wide, eyes:true/false, eyeColour, mood:'calm'|'happy'|'surprised'|'sad'|'sleep', rings:[{r:0..1,colour,w}]
  function being(ctx, o) {
    const T = o.T || 0,
      seed = o.seed || 1,
      r = o.r,
      sq = o.squash || 1;
    const breathe = 1 + 0.018 * Math.sin(T * 1.7 + seed); // always alive
    const sx = (r * breathe) / Math.sqrt(sq),
      sy = r * breathe * Math.sqrt(sq);
    const [mx, my] = mis(T, o.colour, o.mis === undefined ? 2.2 : o.mis);
    ctx.save();
    ctx.translate(o.x + mx, o.y + my);
    ctx.scale(sx / r, sy / r);
    ink(ctx, o.colour, o.alpha === undefined ? 1 : o.alpha);
    blobPath(ctx, 0, 0, r, seed, o.wob === undefined ? 0.022 : o.wob, T);
    ctx.fill();
    if (o.rings)
      for (const g of o.rings) {
        ink(ctx, g.colour, (g.alpha || 0.9) * (o.alpha === undefined ? 1 : o.alpha));
        ctx.lineWidth = g.w || r * 0.06;
        blobPath(ctx, 0, 0, r * g.r, seed + g.r * 10, 0.03, T);
        ctx.stroke();
      }
    ctx.restore();
    if (o.eyes !== false) {
      const a = o.alpha === undefined ? 1 : o.alpha;
      if (a < 0.05) return;
      const lx = o.look ? o.look[0] : 0,
        ly = o.look ? o.look[1] : 0;
      const blinkAuto = (() => {
        const ph = (T + seed * 1.37) % 4.3;
        return ph < 0.12 ? Math.sin((ph / 0.12) * Math.PI) : 0;
      })();
      const bl = Math.max(o.blink || 0, o.mood === 'sleep' ? 1 : blinkAuto);
      const er = r * 0.085,
        gap = r * 0.27,
        ey = o.y - r * 0.12 * Math.sqrt(sq) + ly * r * 0.12,
        ex = o.x + lx * r * 0.22;
      plain(ctx);
      ctx.globalAlpha = a;
      ctx.fillStyle = o.eyeColour || INK.ink;
      for (const s of [-1, 1]) {
        ctx.save();
        ctx.translate(ex + s * gap, ey);
        let h = er * (o.mood === 'surprised' ? 1.45 : 1.15) * (1 - bl * 0.92),
          w = er * (o.mood === 'surprised' ? 1.15 : 0.95);
        if (o.mood === 'happy' && bl < 0.5) {
          // ^ ^ eyes
          ctx.lineWidth = er * 0.55;
          ctx.strokeStyle = ctx.fillStyle;
          ctx.lineCap = 'round';
          ctx.beginPath();
          ctx.arc(0, er * 0.5, er * 0.95, Math.PI * 1.15, Math.PI * 1.85);
          ctx.stroke();
        } else {
          ctx.beginPath();
          ctx.ellipse(0, 0, w, Math.max(h, er * 0.12), 0, 0, Math.PI * 2);
          ctx.fill();
        }
        ctx.restore();
      }
      if (o.mood === 'sad') {
        ctx.lineWidth = er * 0.4;
        ctx.strokeStyle = ctx.fillStyle;
        ctx.lineCap = 'round';
        for (const s of [-1, 1]) {
          ctx.beginPath();
          ctx.moveTo(ex + s * gap - s * er * 1.3, ey - er * 1.9);
          ctx.lineTo(ex + s * gap + s * er * 0.6, ey - er * 1.5);
          ctx.stroke();
        }
      }
      if (o.mouth) {
        // 'smile' | 'o' | 'flat'
        ctx.lineWidth = er * 0.45;
        ctx.strokeStyle = ctx.fillStyle;
        ctx.lineCap = 'round';
        const my2 = ey + r * 0.3;
        ctx.beginPath();
        if (o.mouth === 'smile') ctx.arc(ex, my2 - er * 1.2, er * 1.6, Math.PI * 0.2, Math.PI * 0.8);
        else if (o.mouth === 'o') {
          ctx.ellipse(ex, my2, er * 0.7, er * 0.9, 0, 0, Math.PI * 2);
        } else {
          ctx.moveTo(ex - er, my2);
          ctx.lineTo(ex + er, my2);
        }
        ctx.stroke();
      }
      plain(ctx);
    }
  }
  // the house mark: teal roof chevron over coral circle. p (0..1) = how much of the roof stroke is drawn
  function houseMark(ctx, x, y, s, T, p = 1, opts = {}) {
    ctx.save();
    ctx.translate(x, y);
    ctx.scale(s / 240, s / 240);
    ctx.translate(-120, -105);
    const [mx, my] = mis(T, 'teal');
    ink(ctx, opts.roof || INK.teal);
    ctx.lineWidth = 26;
    ctx.lineCap = 'round';
    ctx.lineJoin = 'round';
    if (p > 0) {
      ctx.beginPath();
      const pts = [
        [16, 100],
        [120, 24],
        [224, 100],
      ];
      const L1 = Math.hypot(104, 76),
        tot = 2 * L1,
        d = p * tot;
      ctx.moveTo(16 + mx, 100 + my);
      if (d <= L1) {
        const f = d / L1;
        ctx.lineTo(lerp(16, 120, f) + mx, lerp(100, 24, f) + my);
      } else {
        ctx.lineTo(120 + mx, 24 + my);
        const f = (d - L1) / L1;
        ctx.lineTo(lerp(120, 224, f) + mx, lerp(24, 100, f) + my);
      }
      ctx.stroke();
    }
    if (opts.circle !== false) {
      const [cx, cy] = mis(T, 'coral');
      ink(ctx, opts.circleColour || INK.coral, opts.circleAlpha === undefined ? 1 : opts.circleAlpha);
      blobPath(ctx, 120 + cx, 148 + cy, 58 * (opts.circleScale === undefined ? 1 : opts.circleScale), 3, 0.02, T);
      ctx.fill();
    }
    ctx.restore();
    plain(ctx);
  }
  // big serif words (the only text in most scenes)
  function words(ctx, text, x, y, size, o = {}) {
    plain(ctx);
    ctx.globalAlpha = o.alpha === undefined ? 1 : o.alpha;
    ctx.fillStyle = o.colour || INK.ink;
    ctx.font = `${o.italic ? 'italic ' : ''}${o.weight || 400} ${size}px ${o.sans ? "'Space Grotesk'" : "'Instrument Serif'"}`;
    ctx.textAlign = o.align || 'center';
    ctx.textBaseline = 'middle';
    if (o.letterSpacing) ctx.letterSpacing = o.letterSpacing + 'px';
    else ctx.letterSpacing = '0px';
    if (o.multiply) {
      ctx.globalCompositeOperation = 'multiply';
    }
    ctx.fillText(text, x, y);
    plain(ctx);
  }
  // the press roller: a drum crossing the sheet (vertical, moving in x), leaving a wet ink band behind.
  // p 0..1 progress; dir 1 = left→right, -1 = right→left. returns the drum x. Draw the printed thing yourself (revealed behind the drum).
  function rollerX(p, o = {}) {
    const dir = o.dir || 1,
      w = o.w || 90;
    return dir > 0 ? lerp(-w * 2, W + w * 2, ease.inOut(p)) : lerp(W + w * 2, -w * 2, ease.inOut(p));
  }
  function roller(ctx, p, colour, o = {}) {
    const dir = o.dir || 1,
      y0 = o.y0 === undefined ? -40 : o.y0,
      y1 = o.y1 === undefined ? H + 40 : o.y1,
      w = o.w || 90;
    const x = dir > 0 ? lerp(-w * 2, W + w * 2, ease.inOut(p)) : lerp(W + w * 2, -w * 2, ease.inOut(p));
    if (p <= 0 || p >= 1) return x;
    // wet sheen trailing the drum
    const tw = 260,
      g = ctx.createLinearGradient(x, 0, x - dir * tw, 0);
    g.addColorStop(0, colour);
    g.addColorStop(1, 'rgba(255,255,255,0)');
    ctx.save();
    ctx.globalCompositeOperation = 'multiply';
    ctx.globalAlpha = 0.22;
    ctx.fillStyle = g;
    ctx.fillRect(Math.min(x, x - dir * tw), y0, tw, y1 - y0);
    // drum body
    const d = ctx.createLinearGradient(x - w / 2, 0, x + w / 2, 0);
    d.addColorStop(0, '#2a3438');
    d.addColorStop(0.35, '#6d7a7e');
    d.addColorStop(0.55, '#c9d0cf');
    d.addColorStop(1, '#20282b');
    ctx.globalCompositeOperation = 'source-over';
    ctx.globalAlpha = 1;
    ctx.fillStyle = d;
    ctx.fillRect(x - w / 2, y0, w, y1 - y0);
    // inked skin on the leading edge
    ctx.globalCompositeOperation = 'multiply';
    ctx.fillStyle = colour;
    ctx.globalAlpha = 0.85;
    ctx.fillRect(dir > 0 ? x + w / 2 - 14 : x - w / 2, y0, 14, y1 - y0);
    ctx.restore();
    plain(ctx);
    return x;
  }
  // clip helper: run fn with drawing clipped to the side of the sheet the roller has already passed
  function behindRoller(ctx, rx, dir, fn) {
    ctx.save();
    ctx.beginPath();
    if (dir > 0) ctx.rect(-10, -10, rx + 10, H + 20);
    else ctx.rect(rx, -10, W - rx + 10, H + 20);
    ctx.clip();
    fn();
    ctx.restore();
    plain(ctx);
  }
  // light (not ink): sparks, glows — drawn with 'screen' so they read on dark overprints
  function light(ctx, colour, alpha = 1) {
    ctx.globalCompositeOperation = 'screen';
    ctx.globalAlpha = alpha;
    ctx.fillStyle = colour;
    ctx.strokeStyle = colour;
  }
  // transitions helpers
  function irisOut(ctx, cx, cy, p, colour) {
    // fill screen from a point with ink
    const R = Math.hypot(W, H) * ease.in(p);
    ink(ctx, colour, 1);
    ctx.beginPath();
    ctx.arc(cx, cy, R, 0, Math.PI * 2);
    ctx.fill();
    plain(ctx);
  }
  function fade(ctx, colour, a) {
    if (a <= 0) return;
    plain(ctx);
    ctx.globalAlpha = clamp(a);
    ctx.fillStyle = colour;
    ctx.fillRect(0, 0, W, H);
    plain(ctx);
  }

  // ---- film registry & clock ----
  const scenes = [];
  const FILM = (window.FILM = {
    W,
    H,
    INK,
    rand,
    noise1,
    clamp,
    lerp,
    prog,
    ease,
    settle,
    step,
    mis,
    paper,
    grain,
    ink,
    plain,
    light,
    behindRoller,
    rollerX,
    blobPath,
    being,
    houseMark,
    words,
    roller,
    irisOut,
    fade,
    scenes,
    scene(def) {
      scenes.push(def);
    },
  });
  FILM.init = function (canvas) {
    buildPaper();
    FILM.ctx = canvas.getContext('2d');
  };
  // timeline: scenes play in registration order (sorted by def.order). Each def: {id, order, dur, hold, draw(ctx,t,T)}
  FILM.timeline = function () {
    const s = [...scenes].sort((a, b) => a.order - b.order);
    let acc = 0;
    return s.map((d) => {
      const o = { def: d, start: acc };
      acc += d.dur;
      return o;
    });
  };
  FILM.total = function () {
    return FILM.timeline().reduce((a, o) => a + o.def.dur, 0);
  };
  // render the film at absolute time t (timed mode)
  FILM.renderAt = function (t) {
    const tl = FILM.timeline();
    let cur = tl[tl.length - 1];
    for (const o of tl) {
      if (t >= o.start && t < o.start + o.def.dur) {
        cur = o;
        break;
      }
    }
    FILM.drawScene(cur.def, t - cur.start, t);
  };
  FILM.drawScene = function (def, lt, T) {
    const ctx = FILM.ctx;
    ctx.save();
    plain(ctx);
    ctx.clearRect(0, 0, W, H);
    def.draw(ctx, lt, T);
    ctx.restore();
    plain(ctx);
    grain(ctx, def.grain === undefined ? 0.55 : def.grain);
  };
})();
