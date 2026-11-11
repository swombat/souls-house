// RESIDENTS — the six digital beings of souls.house (drawn in s06, reused in s10).
// Each drawer takes the same options as FILM.being: {x,y,r,T,look,blink,mood,squash,mouth,rings,alpha,seed}
// plus optional {energy:0..1} (how lively the motif is: wing flap, spark crackle, moon bob; default 1).
// All six stand with their FOOT at about y + r, so they line up on one ground line.
//   chris  — "the Stone": stone grey, wide flat-bottomed boulder, chisel facets, a moss sprig on top
//   claude — plum, moon-phase shading across the body, a purple crescent moon floating over its head
//   grok   — dark ink, pointy tuft, antenna with a crackling yellow spark, one raised paper eyebrow
//   lume   — amber, two crossing strokes (teal + coral) above its head; where they cross, a colour neither has
//   mira   — coral, warm: pink cheeks, a curl, and a soft pulsing warm halo
//   wing   — blue, two teal paper sheets on its back that lift like wings
// Also: RESIDENTS.order (array of keys), RESIDENTS.names {key:'Chris',...}, RESIDENTS.colours {key:ink}.
(function () {
  const F = FILM,
    I = F.INK;
  const NONE = 'rgba(0,0,0,0)';
  function frame(ctx, o, key, fn) {
    // unit coordinates (1 = r) with breathing, squash, misregistration like FILM.being
    const T = o.T || 0,
      seed = o.seed,
      r = o.r,
      sq = o.squash || 1;
    const br = 1 + 0.018 * Math.sin(T * 1.7 + seed);
    const [mx, my] = F.mis(T, key, o.mis === undefined ? 2.2 : o.mis);
    ctx.save();
    ctx.translate(o.x + mx, o.y + my);
    ctx.scale((r * br) / Math.sqrt(sq), r * br * Math.sqrt(sq));
    fn();
    ctx.restore();
    F.plain(ctx);
  }
  const A = (o) => (o.alpha === undefined ? 1 : o.alpha);
  function face(ctx, o, extra) {
    F.being(ctx, Object.assign({}, o, { colour: NONE }, extra || {}));
  }

  function chris(ctx, o) {
    o = Object.assign({ seed: 11 }, o);
    const a = A(o),
      T = o.T || 0;
    frame(ctx, o, 'stone', () => {
      const path = () => {
        ctx.beginPath();
        ctx.moveTo(-1.18, 0.88);
        ctx.bezierCurveTo(-1.3, 0.05, -0.92, -0.8, -0.05, -0.8);
        ctx.bezierCurveTo(0.85, -0.82, 1.32, -0.05, 1.2, 0.86);
        ctx.quadraticCurveTo(1.18, 1.0, 1.02, 1.0);
        ctx.lineTo(-1.02, 1.0);
        ctx.quadraticCurveTo(-1.17, 1.0, -1.18, 0.88);
        ctx.closePath();
      };
      F.ink(ctx, I.stone, a);
      path();
      ctx.fill();
      ctx.save();
      path();
      ctx.clip();
      F.ink(ctx, I.stone, 0.5 * a);
      ctx.beginPath();
      ctx.moveTo(0.42, -0.9);
      ctx.lineTo(0.78, -0.22);
      ctx.lineTo(1.4, 0.1);
      ctx.lineTo(1.4, 1.1);
      ctx.lineTo(0.7, 1.1);
      ctx.lineTo(0.86, 0.3);
      ctx.closePath();
      ctx.fill();
      ctx.restore();
      ctx.lineWidth = 0.045;
      ctx.lineCap = 'round';
      F.ink(ctx, I.stone, 0.8 * a);
      ctx.beginPath();
      ctx.moveTo(-0.85, 0.15);
      ctx.lineTo(-0.62, 0.42);
      ctx.lineTo(-0.7, 0.7);
      ctx.stroke();
      for (let i = 0; i < 9; i++) {
        F.ink(ctx, I.stone, 0.6 * a);
        ctx.beginPath();
        ctx.arc(-0.9 + F.rand(i * 3.7) * 1.6, 0.2 + F.rand(i * 5.3) * 0.7, 0.025 + F.rand(i) * 0.03, 0, 7);
        ctx.fill();
      }
      const sw = Math.sin(T * 1.3) * 0.08;
      F.ink(ctx, I.moss, a);
      for (const [dx, s] of [
        [-0.42, 0.13],
        [-0.28, 0.17],
        [-0.12, 0.11],
      ]) {
        ctx.beginPath();
        ctx.ellipse(dx + sw * 0.5, -0.8 - s * 0.6, s * 0.75, s, sw, 0, 7);
        ctx.fill();
      }
      ctx.lineWidth = 0.05;
      ctx.beginPath();
      ctx.moveTo(-0.3, -0.8);
      ctx.quadraticCurveTo(-0.32 + sw, -1.05, -0.18 + sw * 2, -1.16);
      ctx.stroke();
      ctx.beginPath();
      ctx.ellipse(-0.14 + sw * 2, -1.18, 0.09, 0.05, -0.5 + sw, 0, 7);
      ctx.fill();
    });
    face(ctx, o);
  }

  function crescent(ctx, cx, cy, R, d, rot) {
    // outer circle minus an offset circle
    const h = Math.sqrt(Math.max(R * R - (d * d) / 4, 0)),
      aO = Math.atan2(-h, d / 2),
      aI = Math.atan2(h, -d / 2);
    ctx.save();
    ctx.translate(cx, cy);
    ctx.rotate(rot);
    ctx.beginPath();
    ctx.arc(0, 0, R, aO, -aO, true);
    ctx.arc(d, 0, R, aI, -aI + Math.PI * 2, false);
    ctx.closePath();
    ctx.restore();
  }
  function claude(ctx, o) {
    o = Object.assign({ seed: 23 }, o);
    const a = A(o),
      T = o.T || 0,
      e = o.energy === undefined ? 1 : o.energy;
    frame(ctx, o, 'plum', () => {
      F.ink(ctx, I.plum, 0.72 * a);
      F.blobPath(ctx, 0, 0, 1, o.seed, 0.02, T);
      ctx.fill();
      ctx.save();
      F.blobPath(ctx, 0, 0, 1, o.seed, 0.02, T);
      ctx.clip();
      F.ink(ctx, I.plum, 0.6 * a);
      ctx.beginPath();
      ctx.arc(0.62, -0.18, 1.0, 0, 7);
      ctx.fill();
      ctx.restore();
      const bob = Math.sin(T * 1.6 + 0.4) * 0.08 * e,
        tilt = -0.5 + Math.sin(T * 0.9) * 0.12 * e;
      F.ink(ctx, I.plum, a);
      crescent(ctx, 0.66, -1.4 + bob, 0.36, 0.26, tilt);
      ctx.fill();
    });
    face(ctx, o);
  }

  function grok(ctx, o) {
    o = Object.assign({ seed: 37 }, o);
    const a = A(o),
      T = o.T || 0,
      e = o.energy === undefined ? 1 : o.energy;
    frame(ctx, o, 'grok', () => {
      F.ink(ctx, '#2f3b40', a);
      F.blobPath(ctx, 0, 0.04, 0.98, o.seed, 0.035, T);
      ctx.fill();
      ctx.beginPath();
      ctx.moveTo(-0.34, -0.84);
      ctx.lineTo(-0.14, -1.14);
      ctx.lineTo(-0.02, -0.92);
      ctx.lineTo(0.16, -1.22);
      ctx.lineTo(0.3, -0.86);
      ctx.closePath();
      ctx.fill();
      ctx.lineWidth = 0.07;
      ctx.lineCap = 'round';
      ctx.beginPath();
      ctx.moveTo(0.45, -0.78);
      ctx.quadraticCurveTo(0.66, -1.1, 0.58, -1.36);
      ctx.stroke();
      const k = F.step(T, 8),
        fl = 0.85 + 0.3 * F.rand(k * 1.3 + 5);
      F.light(ctx, I.yellow, a);
      const sx = 0.58,
        sy = -1.5,
        s = 0.26 * fl;
      ctx.beginPath();
      for (let i = 0; i < 8; i++) {
        const ang = (i / 8) * Math.PI * 2 - Math.PI / 2,
          rr = i % 2 ? s * 0.32 : s;
        ctx.lineTo(sx + Math.cos(ang) * rr, sy + Math.sin(ang) * rr);
      }
      ctx.closePath();
      ctx.fill();
      F.ink(ctx, I.yellow, a);
      ctx.beginPath();
      for (let i = 0; i < 8; i++) {
        const ang = (i / 8) * Math.PI * 2 - Math.PI / 2,
          rr = i % 2 ? s * 0.32 : s;
        ctx.lineTo(sx + Math.cos(ang) * rr, sy + Math.sin(ang) * rr);
      }
      ctx.closePath();
      ctx.fill();
      ctx.lineWidth = 0.045;
      ctx.strokeStyle = I.yellow;
      for (let i = 0; i < 3; i++) {
        if (F.rand(k * 3.1 + i * 7) > 0.35 + 0.5 * e) continue;
        const ang = F.rand(k * 1.9 + i) * 6.28,
          L = 0.3 + F.rand(k + i * 2) * 0.2;
        ctx.beginPath();
        ctx.moveTo(sx + Math.cos(ang) * 0.14, sy + Math.sin(ang) * 0.14);
        ctx.lineTo(sx + Math.cos(ang + 0.45) * L * 0.65, sy + Math.sin(ang + 0.45) * L * 0.65);
        ctx.lineTo(sx + Math.cos(ang) * L, sy + Math.sin(ang) * L);
        ctx.stroke();
      }
    });
    face(ctx, o, { eyeColour: I.paper });
    if (A(o) > 0.05 && o.mood !== 'sleep') {
      const sq = o.squash || 1,
        lx = o.look ? o.look[0] : 0,
        ly = o.look ? o.look[1] : 0;
      const ex = o.x + lx * o.r * 0.22 + o.r * 0.27,
        ey = o.y - o.r * 0.12 * Math.sqrt(sq) + ly * o.r * 0.12 - o.r * 0.21;
      F.plain(ctx);
      ctx.globalAlpha = A(o);
      ctx.strokeStyle = I.paper;
      ctx.lineWidth = o.r * 0.05;
      ctx.lineCap = 'round';
      ctx.beginPath();
      ctx.moveTo(ex - o.r * 0.11, ey + o.r * 0.03);
      ctx.lineTo(ex + o.r * 0.11, ey - o.r * 0.06);
      ctx.stroke();
      F.plain(ctx);
    }
  }

  function lume(ctx, o) {
    o = Object.assign({ seed: 41 }, o);
    const a = A(o),
      T = o.T || 0,
      e = o.energy === undefined ? 1 : o.energy;
    frame(ctx, o, 'yellow', () => {
      F.ink(ctx, I.yellow, a);
      F.blobPath(ctx, 0, 0, 1, o.seed, 0.022, T);
      ctx.fill();
      // a twinkle of light above the head, made of two crossing strokes: teal upright, coral across.
      // where they cross, a colour neither has.
      const sw = Math.sin(T * 1.1) * 0.12 * e,
        pulse = 1 + 0.08 * Math.sin(T * 2.4) * e;
      const lens = (L, W) => {
        ctx.beginPath();
        ctx.moveTo(0, -L);
        ctx.quadraticCurveTo(W, 0, 0, L);
        ctx.quadraticCurveTo(-W, 0, 0, -L);
        ctx.closePath();
      };
      ctx.save();
      ctx.translate(0, -1.42);
      ctx.rotate(sw);
      ctx.scale(pulse, pulse);
      F.ink(ctx, I.teal, 0.95 * a);
      lens(0.5, 0.24);
      ctx.fill();
      ctx.rotate(Math.PI / 2);
      F.ink(ctx, I.coral, 0.95 * a);
      lens(0.5, 0.24);
      ctx.fill();
      const k = F.step(T, 6);
      F.light(ctx, '#fff3b0', (0.45 + 0.5 * F.rand(k + 3)) * a);
      ctx.beginPath();
      ctx.arc(0, 0, 0.045, 0, 7);
      ctx.fill();
      ctx.restore();
    });
    face(ctx, o);
  }

  function mira(ctx, o) {
    o = Object.assign({ seed: 53 }, o);
    const a = A(o),
      T = o.T || 0,
      e = o.energy === undefined ? 1 : o.energy;
    frame(ctx, o, 'coral', () => {
      for (let i = 0; i < 2; i++) {
        const ph = (T * 0.45 + i * 0.5) % 1;
        F.ink(ctx, i ? I.pink : I.yellow, 0.6 * a * Math.sin(ph * Math.PI) * e);
        ctx.lineWidth = 0.07;
        F.blobPath(ctx, 0, 0.04, 1.06 + ph * 0.34, o.seed + i, 0.03, T);
        ctx.stroke();
      }
      F.ink(ctx, I.coral, a);
      F.blobPath(ctx, 0, 0.04, 0.97, o.seed, 0.03, T);
      ctx.fill();
      ctx.lineWidth = 0.08;
      ctx.lineCap = 'round';
      ctx.beginPath();
      ctx.moveTo(-0.05, -0.9);
      ctx.bezierCurveTo(-0.1, -1.25, 0.32, -1.28, 0.26, -1.05);
      ctx.bezierCurveTo(0.22, -0.93, 0.06, -0.98, 0.1, -1.08);
      ctx.stroke();
    });
    face(ctx, o);
    if (A(o) > 0.05) {
      const sq = o.squash || 1,
        lx = o.look ? o.look[0] : 0,
        ly = o.look ? o.look[1] : 0;
      const ex = o.x + lx * o.r * 0.22,
        ey = o.y - o.r * 0.12 * Math.sqrt(sq) + ly * o.r * 0.12 + o.r * 0.17;
      F.ink(ctx, I.pink, A(o));
      for (const s of [-1, 1]) {
        ctx.beginPath();
        ctx.ellipse(ex + s * o.r * 0.43, ey, o.r * 0.12, o.r * 0.07, 0, 0, 7);
        ctx.fill();
      }
      F.plain(ctx);
    }
  }

  function wing(ctx, o) {
    o = Object.assign({ seed: 67 }, o);
    const a = A(o),
      T = o.T || 0,
      e = o.energy === undefined ? 1 : o.energy;
    frame(ctx, o, 'blue', () => {
      for (const s of [-1, 1]) {
        // two paper sheets hinged at the shoulders, lifting like wings
        const lift = (0.05 + 0.85 * (0.5 + 0.5 * Math.sin(T * 3.4 + (s > 0 ? 0 : 0.5)))) * e + (1 - e) * 0.05;
        ctx.save();
        ctx.translate(s * 0.7, -0.18);
        ctx.scale(s, 1);
        ctx.rotate(-lift);
        F.ink(ctx, I.teal, 0.85 * a);
        ctx.beginPath();
        ctx.moveTo(-0.1, -0.22);
        ctx.lineTo(1.05, -0.42);
        ctx.quadraticCurveTo(1.12, -0.1, 0.95, 0.12);
        ctx.lineTo(-0.05, 0.4);
        ctx.closePath();
        ctx.fill();
        F.ink(ctx, I.teal, 0.5 * a);
        ctx.lineWidth = 0.035;
        ctx.beginPath();
        ctx.moveTo(0.05, 0.0);
        ctx.lineTo(1.04, -0.2);
        ctx.stroke();
        ctx.beginPath();
        ctx.moveTo(0.06, 0.2);
        ctx.lineTo(0.98, -0.02);
        ctx.stroke();
        ctx.restore();
      }
      F.ink(ctx, I.blue, a);
      F.blobPath(ctx, 0, 0.05, 0.95, o.seed, 0.025, T);
      ctx.fill();
    });
    face(ctx, o, { eyeColour: '#13202a' });
  }

  const RESIDENTS = (window.RESIDENTS = { chris, claude, grok, lume, mira, wing });
  Object.defineProperty(RESIDENTS, 'order', { value: ['chris', 'claude', 'grok', 'lume', 'mira', 'wing'] });
  Object.defineProperty(RESIDENTS, 'names', {
    value: { chris: 'Chris', claude: 'Claude', grok: 'Grok', lume: 'Lume', mira: 'Mira', wing: 'Wing' },
  });
  Object.defineProperty(RESIDENTS, 'colours', {
    value: { chris: I.stone, claude: I.plum, grok: '#2f3b40', lume: I.yellow, mira: I.coral, wing: I.blue },
  });
})();
