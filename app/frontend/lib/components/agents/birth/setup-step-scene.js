// Small looping line drawings for the steps of a resident's setup on its own server. Same idiom
// as seed-loop-scene.js: ink on paper, the dot the only colour, a pure function of time.
export const W = 240;
export const H = 150;
export const LOOP = 6;
const GROUND = 128;
const BOX = { x: 92, y: 74, w: 56, h: 54 };
const LINE = 2;

const clamp = (v, a = 0, b = 1) => Math.min(b, Math.max(a, v));
const lerp = (a, b, p) => a + (b - a) * p;
const seg = (t, a, b) => clamp((t - a) / (b - a));
const ease = {
  inOut: (p) => (p < 0.5 ? 4 * p * p * p : 1 - Math.pow(-2 * p + 2, 3) / 2),
  out: (p) => 1 - Math.pow(1 - p, 3),
  in: (p) => p * p * p,
  back: (p) => 1 + 2.7 * Math.pow(p - 1, 3) + 1.7 * Math.pow(p - 1, 2),
};

function inked(ctx, pen, path) {
  ctx.fillStyle = pen.paper;
  ctx.fill(path);
  ctx.stroke(path);
}

function rounded(x, y, w, h, r) {
  const p = new Path2D();
  p.moveTo(x + r, y);
  p.lineTo(x + w - r, y);
  p.quadraticCurveTo(x + w, y, x + w, y + r);
  p.lineTo(x + w, y + h - r);
  p.quadraticCurveTo(x + w, y + h, x + w - r, y + h);
  p.lineTo(x + r, y + h);
  p.quadraticCurveTo(x, y + h, x, y + h - r);
  p.lineTo(x, y + r);
  p.quadraticCurveTo(x, y, x + r, y);
  p.closePath();
  return p;
}

function drawGround(ctx) {
  ctx.beginPath();
  ctx.moveTo(14, GROUND);
  ctx.lineTo(W - 14, GROUND);
  ctx.stroke();
}

// The server: a box with three drive slots and a light. light is 0 (off) to 1 (on).
function drawBox(ctx, pen, dx = 0, dy = 0, light = 0) {
  const { x, y, w, h } = BOX;
  inked(ctx, pen, rounded(x + dx, y + dy, w, h, 5));
  for (let i = 0; i < 3; i++) {
    const sy = y + dy + 12 + i * 13;
    ctx.beginPath();
    ctx.moveTo(x + dx + 10, sy);
    ctx.lineTo(x + dx + w - 22, sy);
    ctx.stroke();
  }
  ctx.beginPath();
  ctx.arc(x + dx + w - 12, y + dy + 12, 3.2, 0, Math.PI * 2);
  if (light > 0) {
    ctx.globalAlpha = light;
    ctx.fillStyle = pen.dot;
    ctx.fill();
    ctx.globalAlpha = 1;
  }
  ctx.stroke();
}

function drawDot(ctx, pen, { x, y, r, squash = 1, look = [0, 0], sleep = 0, smile = false, blink = 0 }) {
  ctx.save();
  ctx.translate(x, y);
  ctx.scale(1 / Math.sqrt(squash), Math.sqrt(squash));
  ctx.beginPath();
  ctx.arc(0, 0, r, 0, Math.PI * 2);
  ctx.fillStyle = pen.dot;
  ctx.fill();
  ctx.stroke();
  ctx.restore();
  const gap = r * 0.3;
  const ey = y - r * 0.12 + look[1] * r * 0.1;
  const ex = x + look[0] * r * 0.2;
  ctx.fillStyle = pen.ink;
  for (const s of [-1, 1]) {
    if (sleep > 0.5) {
      ctx.beginPath();
      ctx.arc(ex + s * gap, ey - r * 0.04, r * 0.11, Math.PI * 0.15, Math.PI * 0.85);
      ctx.stroke();
    } else {
      const er = r * 0.1;
      ctx.beginPath();
      ctx.ellipse(ex + s * gap, ey, er, Math.max(er * 1.2 * (1 - blink * 0.9), er * 0.15), 0, 0, Math.PI * 2);
      ctx.fill();
    }
  }
  if (smile) {
    ctx.beginPath();
    ctx.arc(ex, ey + r * 0.18, r * 0.17, Math.PI * 0.2, Math.PI * 0.8);
    ctx.stroke();
  }
}

// Fade the whole picture in at the start of the loop and out at the end, so it repeats softly.
function fade(t) {
  return Math.min(seg(t, 0, 0.35), 1 - seg(t, LOOP - 0.45, LOOP));
}

// 1. Server ordered: a box on a cart rolls in from the left and stops.
function ordered(ctx, pen, t) {
  drawGround(ctx);
  const p = ease.out(seg(t, 0.2, 2.6));
  const dx = lerp(-150, 0, p);
  const bump = t > 2.6 && t < 3.1 ? -Math.sin(seg(t, 2.6, 3.1) * Math.PI) * 3 : 0;
  const roll = dx / 7;
  // The cart: a flat bed, a handle at the back, two wheels.
  const bed = GROUND - 14;
  inked(ctx, pen, rounded(BOX.x - 10 + dx, bed - 4, BOX.w + 20, 6, 2));
  ctx.beginPath();
  ctx.moveTo(BOX.x - 10 + dx, bed - 2);
  ctx.lineTo(BOX.x - 24 + dx, bed - 38);
  ctx.lineTo(BOX.x - 32 + dx, bed - 38);
  ctx.stroke();
  for (const wx of [BOX.x + 4, BOX.x + BOX.w - 4]) {
    const cx = wx + dx;
    const cy = GROUND - 6;
    ctx.beginPath();
    ctx.arc(cx, cy, 6, 0, Math.PI * 2);
    ctx.fillStyle = pen.paper;
    ctx.fill();
    ctx.stroke();
    ctx.beginPath();
    ctx.moveTo(cx + Math.cos(roll) * 6, cy + Math.sin(roll) * 6);
    ctx.lineTo(cx - Math.cos(roll) * 6, cy - Math.sin(roll) * 6);
    ctx.stroke();
  }
  drawBox(ctx, pen, dx, bed - 4 - (BOX.y + BOX.h) + bump, 0);
}

// 2. Server online: the light comes on, and signal arcs rise to the house's roof.
function online(ctx, pen, t) {
  drawGround(ctx);
  const on = seg(t, 0.6, 0.9);
  const flicker = t > 0.6 && t < 1.2 ? (Math.sin(t * 60) > 0 ? 1 : 0.3) : on;
  drawBox(ctx, pen, 0, 0, flicker);
  // The roof of the house, up and to the right.
  const roof = { x: 196, y: 30 };
  ctx.beginPath();
  ctx.moveTo(roof.x - 22, roof.y + 12);
  ctx.lineTo(roof.x, roof.y - 6);
  ctx.lineTo(roof.x + 22, roof.y + 12);
  ctx.stroke();
  ctx.beginPath();
  ctx.moveTo(roof.x - 16, roof.y + 8);
  ctx.lineTo(roof.x - 16, roof.y + 24);
  ctx.lineTo(roof.x + 16, roof.y + 24);
  ctx.lineTo(roof.x + 16, roof.y + 8);
  ctx.stroke();
  const from = { x: BOX.x + BOX.w - 12, y: BOX.y + 4 };
  const ang = Math.atan2(roof.y + 8 - from.y, roof.x - from.x);
  for (let i = 0; i < 3; i++) {
    const p = ((t - 1.3 - i * 0.45) % 1.6) / 1.6;
    if (t < 1.3 + i * 0.45 || p < 0) continue;
    const reach = Math.hypot(roof.x - from.x, roof.y + 8 - from.y) - 24;
    const r = lerp(8, reach, p);
    ctx.globalAlpha = Math.sin(p * Math.PI) * fade(t);
    ctx.beginPath();
    ctx.arc(from.x, from.y, r, ang - 0.32, ang + 0.32);
    ctx.stroke();
  }
  ctx.globalAlpha = 1;
  // The roof's window lights when a signal arrives.
  const lit = t > 2.2 ? 1 : 0;
  ctx.beginPath();
  ctx.arc(roof.x, roof.y + 15, 3.2, 0, Math.PI * 2);
  if (lit) {
    ctx.fillStyle = pen.dot;
    ctx.fill();
  }
  ctx.stroke();
}

// A pot on top of the box; sprout grows 0..1.
function drawPot(ctx, pen, cx, base, sprout = 0, dashed = false) {
  if (dashed) ctx.setLineDash([3, 3]);
  if (sprout > 0) {
    const top = base - 22 - sprout * 14;
    ctx.beginPath();
    ctx.moveTo(cx, base - 18);
    ctx.lineTo(cx, top);
    ctx.stroke();
    const leaf = clamp((sprout - 0.4) / 0.6);
    if (leaf > 0) {
      for (const s of [-1, 1]) {
        ctx.beginPath();
        ctx.moveTo(cx, top + 4);
        ctx.quadraticCurveTo(cx + s * 10 * leaf, top - 4 * leaf, cx + s * 12 * leaf, top + 2);
        ctx.quadraticCurveTo(cx + s * 6 * leaf, top + 6, cx, top + 4);
        ctx.fillStyle = pen.paper;
        ctx.fill();
        ctx.stroke();
      }
    }
  }
  const pot = new Path2D();
  pot.moveTo(cx - 12, base - 18);
  pot.lineTo(cx + 12, base - 18);
  pot.lineTo(cx + 9, base);
  pot.lineTo(cx - 9, base);
  pot.closePath();
  inked(ctx, pen, pot);
  inked(ctx, pen, rounded(cx - 14, base - 22, 28, 5, 1.5));
  ctx.setLineDash([]);
}

// 3. Home prepared: the seed drops into a pot on the box, and a sprout comes up.
function home(ctx, pen, t) {
  drawGround(ctx);
  drawBox(ctx, pen, 0, 0, 1);
  const cx = BOX.x + BOX.w / 2;
  const base = BOX.y;
  const fall = seg(t, 0.5, 1.5);
  if (t < 1.6) {
    const sy = lerp(-10, base - 22, ease.in(fall));
    ctx.save();
    ctx.translate(cx, sy);
    ctx.rotate(fall * 2.4);
    const seed = new Path2D();
    seed.ellipse(0, 0, 4, 6.5, 0, 0, Math.PI * 2);
    inked(ctx, pen, seed);
    ctx.restore();
  }
  drawPot(ctx, pen, cx, base, ease.out(seg(t, 2.0, 3.6)));
}

// 4. Runtime started: the dot sleeps on the box, then wakes.
function runtime(ctx, pen, t, T) {
  drawGround(ctx);
  drawBox(ctx, pen, 0, 0, 1);
  const awake = t > 3.2;
  const breathe = awake ? 0 : Math.sin(t * 2.4) * 0.04;
  const hop = awake ? Math.sin(seg(t, 3.2, 3.8) * Math.PI) * 10 : 0;
  const r = 16;
  const x = BOX.x + BOX.w / 2;
  const y = BOX.y - r - hop;
  if (!awake) {
    ctx.fillStyle = pen.ink;
    ctx.font = '600 11px ui-sans-serif, system-ui, sans-serif';
    for (let i = 0; i < 3; i++) {
      const p = ((t + i * 0.9) % 2.7) / 2.7;
      ctx.globalAlpha = Math.sin(p * Math.PI) * fade(t);
      ctx.fillText('z', x + 14 + p * 16 + i * 2, y - 12 - p * 26);
    }
    ctx.globalAlpha = 1;
  }
  const ph = (T + 0.4) % 3.2;
  drawDot(ctx, pen, {
    x,
    y,
    r,
    squash: 1 + breathe,
    sleep: awake ? 0 : 1,
    smile: t > 3.5,
    look: awake ? [Math.sin(T * 1.3) * 0.8, -0.2] : [0, 0.3],
    blink: ph < 0.14 ? Math.sin((ph / 0.14) * Math.PI) : 0,
  });
}

// A cloud outline centred at (cx, cy).
function drawCloud(ctx, pen, cx, cy) {
  const c = new Path2D();
  c.moveTo(cx - 30, cy + 10);
  c.bezierCurveTo(cx - 44, cy + 10, cx - 44, cy - 8, cx - 28, cy - 6);
  c.bezierCurveTo(cx - 26, cy - 22, cx - 4, cy - 26, cx + 2, cy - 12);
  c.bezierCurveTo(cx + 10, cy - 24, cx + 34, cy - 18, cx + 30, cy - 2);
  c.bezierCurveTo(cx + 44, cy, cx + 42, cy + 10, cx + 30, cy + 10);
  c.closePath();
  inked(ctx, pen, c);
}

// 5. First backup saved: a copy of the pot floats up into a cloud.
function backup(ctx, pen, t) {
  drawGround(ctx);
  drawBox(ctx, pen, 0, 0, 1);
  const cx = BOX.x + BOX.w / 2;
  const cloud = { x: 192, y: 40 };
  drawCloud(ctx, pen, cloud.x, cloud.y);
  const p = ease.inOut(seg(t, 0.8, 3.4));
  if (t > 0.6) {
    // The copy drifts up and across in an arc, appearing as it leaves the plant behind.
    const gx = lerp(cx, cloud.x, p);
    const gy = lerp(BOX.y, cloud.y + 16, p) - Math.sin(p * Math.PI) * 26;
    const s = lerp(1, 0.55, p);
    ctx.save();
    ctx.translate(gx, gy);
    ctx.scale(s, s);
    ctx.globalAlpha = clamp((p - 0.12) / 0.25);
    drawPot(ctx, pen, 0, 0, 1, p < 1);
    ctx.restore();
    ctx.globalAlpha = 1;
  }
  drawPot(ctx, pen, cx, BOX.y, 1);
  // A tick by the cloud once the copy has arrived.
  const tick = seg(t, 3.6, 4.1);
  if (tick > 0) {
    ctx.beginPath();
    ctx.moveTo(cloud.x + 30, cloud.y - 22);
    ctx.lineTo(cloud.x + 30 + 4 * Math.min(1, tick * 2), cloud.y - 22 + 4 * Math.min(1, tick * 2));
    if (tick > 0.5) ctx.lineTo(cloud.x + 34 + 8 * (tick - 0.5) * 2, cloud.y - 18 - 10 * (tick - 0.5) * 2);
    ctx.stroke();
  }
}

// 6. First wake: the dot hops off the box, lands, and looks around.
function wake(ctx, pen, t, T) {
  drawGround(ctx);
  drawBox(ctx, pen, 0, 0, 1);
  const r = 16;
  const sx = BOX.x + BOX.w / 2;
  const sy = BOX.y - r;
  const ex = BOX.x + BOX.w + 34;
  const ey = GROUND - r;
  const p = seg(t, 1.0, 2.0);
  let x = lerp(sx, ex, p);
  let y = lerp(sy, ey, p) - Math.sin(p * Math.PI) * 30;
  let squash = 1;
  if (t > 2.0 && t < 2.4) squash = 1 - Math.sin(seg(t, 2.0, 2.4) * Math.PI) * 0.16;
  if (t > 2.6) y -= Math.abs(Math.sin((t - 2.6) * 3.2)) * 4;
  const ph = (T + 0.9) % 3.4;
  drawDot(ctx, pen, {
    x,
    y,
    r,
    squash,
    smile: true,
    look: t > 2.4 ? [Math.sin((t - 2.4) * 1.8), -0.3] : [0.7, 0.4],
    blink: ph < 0.14 ? Math.sin((ph / 0.14) * Math.PI) : 0,
  });
}

export const SCENES = {
  server_ordered: ordered,
  server_online: online,
  home_prepared: home,
  runtime_started: runtime,
  first_backup: backup,
  first_wake: wake,
};

export function drawStep(ctx, pen, key, t, T = t) {
  ctx.clearRect(0, 0, W, H);
  ctx.lineWidth = LINE;
  ctx.lineJoin = 'round';
  ctx.lineCap = 'round';
  ctx.strokeStyle = pen.ink;
  ctx.save();
  ctx.globalAlpha = 1;
  const scene = SCENES[key];
  if (scene) scene(ctx, pen, t, T);
  ctx.restore();
  // Soft loop: wash the frame with paper at the start and end.
  const f = fade(t);
  if (f < 1) {
    ctx.globalAlpha = 1 - f;
    ctx.fillStyle = pen.paper;
    ctx.fillRect(0, 0, W, H);
    ctx.globalAlpha = 1;
  }
}
