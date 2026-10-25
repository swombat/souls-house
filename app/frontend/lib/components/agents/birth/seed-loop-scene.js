// The seed-loop scene: a hand drops a seed; the ground closes over it; a root and a stem, leaves and
// a bud grow; the bud opens and a dot with a face climbs out. The plant fades back, the dot drifts
// away, the hand returns. Line art in the card's own ink on the card's own paper; the only colour is
// the dot. A pure function of time on a 12 second loop, so any frame can be drawn on its own.
// Nothing here touches Svelte: seed-loop.svelte owns the canvas and the animation frame.

export const W = 200;
export const H = 360;
export const LOOP = 12;
const GROUND = 292;
const STEM_X = 100;
const SEED_Y = GROUND + 12;
const TIP = { x: STEM_X, y: 176 };
const LINE = 2;
const HAND_SCALE = 0.95;
const PINCH_Y = 150;

const clamp = (v, a = 0, b = 1) => Math.min(b, Math.max(a, v));
const lerp = (a, b, p) => a + (b - a) * p;
const seg = (t, a, b) => clamp((t - a) / (b - a));
const ease = {
  inOut: (p) => (p < 0.5 ? 4 * p * p * p : 1 - Math.pow(-2 * p + 2, 3) / 2),
  out: (p) => 1 - Math.pow(1 - p, 3),
  in: (p) => p * p * p,
  back: (p) => {
    const c = 1.7;
    return 1 + (c + 1) * Math.pow(p - 1, 3) + c * Math.pow(p - 1, 2);
  },
};

const quad = (p0, p1, p2, t) => {
  const u = 1 - t;
  return [u * u * p0[0] + 2 * u * t * p1[0] + t * t * p2[0], u * u * p0[1] + 2 * u * t * p1[1] + t * t * p2[1]];
};

// Ink on paper: every shape is filled with the paper (so it hides what is behind it) and outlined.
function inked(ctx, pen, path) {
  ctx.fillStyle = pen.paper;
  ctx.fill(path);
  ctx.stroke(path);
}

// A finger: a tapered tube along a quadratic curve with a round tip.
function limb(ctx, pen, p0, p1, p2, w0, w1) {
  const N = 24;
  const left = [];
  const right = [];
  for (let i = 0; i <= N; i++) {
    const t = i / N;
    const a = quad(p0, p1, p2, Math.max(0, t - 0.01));
    const b = quad(p0, p1, p2, Math.min(1, t + 0.01));
    let dx = b[0] - a[0];
    let dy = b[1] - a[1];
    const d = Math.hypot(dx, dy) || 1;
    dx /= d;
    dy /= d;
    const w = lerp(w0, w1, t) / 2;
    const c = quad(p0, p1, p2, t);
    left.push([c[0] - dy * w, c[1] + dx * w]);
    right.push([c[0] + dy * w, c[1] - dx * w]);
  }
  const tip = quad(p0, p1, p2, 1);
  const pre = quad(p0, p1, p2, 0.98);
  const ang = Math.atan2(tip[1] - pre[1], tip[0] - pre[0]);
  const path = new Path2D();
  path.moveTo(...left[0]);
  left.forEach((p) => path.lineTo(...p));
  path.arc(tip[0], tip[1], w1 / 2, ang + Math.PI / 2, ang - Math.PI / 2, true);
  for (let i = N; i >= 0; i--) path.lineTo(...right[i]);
  inked(ctx, pen, path);
}

function handAt(t) {
  if (t < 1.4) return { y: lerp(-80, PINCH_Y, ease.out(seg(t, 0, 1.4))), open: 0 };
  if (t < 2.1) return { y: PINCH_Y, open: ease.inOut(seg(t, 1.45, 1.75)) };
  return { y: lerp(PINCH_Y, -110, ease.in(seg(t, 2.1, 3.0))), open: 1 };
}

// Drawn with the pinch (where the seed is held) at the origin, the arm reaching up out of frame.
function drawHand(ctx, pen, hand) {
  if (hand.y < -70) return;
  const o = hand.open;
  const P = (d) => new Path2D(d);
  ctx.save();
  ctx.translate(STEM_X - 8, hand.y + 4);
  ctx.scale(HAND_SCALE, HAND_SCALE);
  ctx.lineWidth = LINE / HAND_SCALE;
  inked(ctx, pen, P('M 12 -240 L 13 -102 L 55 -102 L 57 -240 Z'));
  // Index finger, tucked behind the palm's edge; it swings out to let go.
  ctx.save();
  ctx.translate(30, -60);
  ctx.rotate(-0.25 * o);
  limb(ctx, pen, [0, 0], [4, 30], [-20, 56], 16, 11);
  ctx.stroke(P('M -6 34 q 4 3 9 2'));
  ctx.restore();
  // The palm, with the other three fingers curled under it.
  inked(
    ctx,
    pen,
    P(
      'M 14 -102 C 10 -88 10 -74 16 -64 C 22 -56 30 -52 36 -50 C 38 -42 46 -38 52 -42 C 58 -46 58 -52 56 -55 C 62 -58 63 -65 60 -68 C 65 -72 64 -80 60 -82 C 60 -90 58 -96 56 -102 Z'
    )
  );
  ctx.stroke(P('M 40 -52 C 46 -54 52 -56 56 -55 M 44 -64 C 50 -66 56 -68 60 -68'));
  // Thumb on top, swinging the other way.
  ctx.save();
  ctx.translate(18, -80);
  ctx.rotate(0.38 * o);
  limb(ctx, pen, [0, 0], [-20, 24], [-12, 66], 19, 12);
  ctx.stroke(P('M -15 58 q 3 4 7 3'));
  ctx.restore();
  // Shirt cuff over the wrist.
  inked(ctx, pen, P('M 9 -112 Q 34 -104 59 -112 L 58 -98 Q 34 -90 10 -98 Z'));
  ctx.restore();
  ctx.lineWidth = LINE;
}

function seedAt(t, hand) {
  if (t < 1.6) return { x: STEM_X, y: hand.y + 4, spin: 0.5, visible: hand.y > -40 };
  if (t < 2.45) {
    const p = ease.in(seg(t, 1.6, 2.45));
    return { x: STEM_X, y: lerp(PINCH_Y + 4, SEED_Y, p), spin: lerp(0.5, 0.15, p), visible: true };
  }
  return { x: STEM_X, y: SEED_Y, spin: 0.15, visible: t < 8.8 };
}

function drawSeed(ctx, pen, seed, t) {
  if (!seed.visible) return;
  // Once the shoot is up the husk fades back with the rest of the plant.
  ctx.globalAlpha = t > 5 ? plantAlpha(t) : 1;
  ctx.save();
  ctx.translate(seed.x, seed.y);
  ctx.rotate(seed.spin);
  const husk = new Path2D('M 0 -9 C 6 -7 7 4 0 9 C -7 4 -6 -7 0 -9 Z');
  inked(ctx, pen, husk);
  ctx.stroke(new Path2D('M 0 -6 C 2 -2 2 3 0 6'));
  ctx.restore();
  ctx.globalAlpha = 1;
}

function holeOpen(t) {
  if (t < 2.6) return 1;
  if (t < 3.2) return 1 - ease.inOut(seg(t, 2.6, 3.2));
  if (t < 11.1) return 0;
  return ease.inOut(seg(t, 11.1, 11.8));
}

// The ground is a line with a dip where the hole is, a few tufts, and pebbles below it.
function drawGround(ctx, pen, t) {
  const open = holeOpen(t);
  const dip = 14 * open;
  const half = 18;
  ctx.globalAlpha = 1;
  ctx.beginPath();
  ctx.moveTo(10, GROUND + 4);
  ctx.quadraticCurveTo(50, GROUND - 2, STEM_X - half - 6, GROUND);
  ctx.lineTo(STEM_X - half, GROUND);
  ctx.bezierCurveTo(STEM_X - half + 4, GROUND + dip, STEM_X + half - 4, GROUND + dip, STEM_X + half, GROUND);
  ctx.lineTo(STEM_X + half + 6, GROUND);
  ctx.quadraticCurveTo(150, GROUND - 2, W - 10, GROUND + 4);
  ctx.stroke();
  // A small mound over the planted seed, flattening as the shoot comes up.
  const mound = seg(t, 2.9, 3.3) * (1 - seg(t, 4.2, 5.2));
  if (mound > 0.01) {
    ctx.beginPath();
    ctx.moveTo(STEM_X - 16, GROUND);
    ctx.quadraticCurveTo(STEM_X, GROUND - 9 * mound, STEM_X + 16, GROUND);
    ctx.stroke();
  }
  // Grass tufts and pebbles.
  for (const [x, s] of [
    [30, 1],
    [164, -1],
  ]) {
    ctx.beginPath();
    ctx.moveTo(x, GROUND + 1);
    ctx.quadraticCurveTo(x - 2 * s, GROUND - 6, x - 6 * s, GROUND - 10);
    ctx.moveTo(x + 3, GROUND + 1);
    ctx.quadraticCurveTo(x + 3, GROUND - 8, x + 4 * s, GROUND - 13);
    ctx.moveTo(x + 6, GROUND + 1);
    ctx.quadraticCurveTo(x + 8 * s, GROUND - 5, x + 12 * s, GROUND - 7);
    ctx.stroke();
  }
  for (const [x, y, r] of [
    [42, 318, 4],
    [152, 326, 5],
    [74, 342, 3],
    [176, 346, 3],
  ]) {
    ctx.beginPath();
    ctx.ellipse(x, y, r * 1.3, r, 0.2, 0, Math.PI * 2);
    ctx.stroke();
  }
}

// Two clods of earth slide in from either side and meet over the seed.
function drawClosingSoil(ctx, pen, t) {
  const p = seg(t, 2.6, 3.2);
  if (p <= 0 || t > 3.5) return;
  ctx.globalAlpha = 1 - seg(t, 3.2, 3.5);
  for (const side of [-1, 1]) {
    const x = STEM_X + side * lerp(28, 8, ease.inOut(p));
    const clod = new Path2D();
    clod.ellipse(x, GROUND + 1, 10, 6, side * 0.2, 0, Math.PI * 2);
    inked(ctx, pen, clod);
  }
  ctx.globalAlpha = 1;
}

function plantAlpha(t) {
  if (t < 7.6) return 1;
  if (t < 10.2) return lerp(1, 0.22, ease.inOut(seg(t, 7.6, 8.8)));
  return lerp(0.22, 0, seg(t, 10.2, 11.0));
}

function drawRoots(ctx, t) {
  const r = ease.out(seg(t, 3.3, 5.2));
  if (r <= 0) return;
  ctx.globalAlpha = plantAlpha(t);
  for (const [dx, len, bend] of [
    [-2, 26, -8],
    [2, 20, 9],
    [0, 34, 2],
  ]) {
    const end = [STEM_X + dx + bend * r, SEED_Y + 8 + len * r];
    ctx.beginPath();
    ctx.moveTo(STEM_X + dx * 0.5, SEED_Y + 8);
    ctx.quadraticCurveTo(STEM_X + dx - bend * 0.5 * r, SEED_Y + 8 + len * 0.5 * r, end[0], end[1]);
    ctx.stroke();
  }
  ctx.globalAlpha = 1;
}

function leafPath(len, width) {
  const p = new Path2D();
  p.moveTo(0, 0);
  p.quadraticCurveTo(width, -len * 0.45, 0, -len);
  p.quadraticCurveTo(-width, -len * 0.45, 0, 0);
  p.closePath();
  return p;
}

function drawPlant(ctx, pen, t, T) {
  const grow = ease.out(seg(t, 3.3, 5.0));
  if (grow <= 0) return;
  const alpha = plantAlpha(t);
  if (alpha <= 0.01) return;
  ctx.globalAlpha = alpha;
  const sway = Math.sin(T * 0.9) * 3;
  const tipY = lerp(SEED_Y - 8, TIP.y, grow);
  const tipX = STEM_X + sway * grow;
  ctx.beginPath();
  ctx.moveTo(STEM_X, SEED_Y - 8);
  ctx.quadraticCurveTo(STEM_X - 10 * grow, lerp(GROUND, TIP.y, 0.55), tipX, tipY);
  ctx.stroke();

  const leaves = ease.back(seg(t, 4.0, 5.0));
  if (leaves > 0) {
    for (const [side, at, size] of [
      [-1, 0.3, 1],
      [1, 0.5, 0.85],
    ]) {
      const ly = lerp(GROUND, TIP.y, at * Math.max(grow, 0.6));
      const lx = STEM_X - 6 * at;
      ctx.save();
      ctx.translate(lx, ly);
      ctx.rotate(side * (0.95 + Math.sin(T * 1.1 + side) * 0.06));
      ctx.scale(leaves * size, leaves * size);
      ctx.lineWidth = LINE / Math.max(leaves * size, 0.3);
      inked(ctx, pen, leafPath(32, 13));
      ctx.beginPath();
      ctx.moveTo(0, -2);
      ctx.quadraticCurveTo(1.5, -16, 0, -27);
      ctx.stroke();
      ctx.restore();
    }
    ctx.lineWidth = LINE;
  }

  const bud = ease.back(seg(t, 4.8, 5.8));
  if (bud > 0) {
    const opening = ease.inOut(seg(t, 5.9, 6.7));
    ctx.save();
    ctx.translate(tipX, tipY);
    ctx.scale(bud, bud);
    ctx.lineWidth = LINE / Math.max(bud, 0.3);
    // Petals, outer ones first so the middle one overlaps them; folded into a bud, then turning out.
    for (const i of [0, 4, 1, 3, 2]) {
      const spread = (i - 2) * lerp(0.17, 0.6, opening);
      ctx.save();
      ctx.rotate(spread);
      const petal = new Path2D();
      petal.ellipse(0, lerp(-12, -16, opening), lerp(6.5, 8, opening), lerp(13, 15, opening), 0, 0, Math.PI * 2);
      inked(ctx, pen, petal);
      ctx.restore();
    }
    // Sepals cupping the base.
    for (const side of [-1, 1]) {
      ctx.save();
      ctx.rotate(side * lerp(0.4, 1.15, opening));
      inked(ctx, pen, leafPath(16, 6));
      ctx.restore();
    }
    ctx.restore();
    ctx.lineWidth = LINE;
  }
  ctx.globalAlpha = 1;
}

function dotAt(t, T) {
  const rise = seg(t, 6.5, 7.4);
  if (rise <= 0 || t > 11) return null;
  const r = lerp(5, 26, ease.back(rise));
  let x = TIP.x;
  let y = lerp(TIP.y - 6, TIP.y - 44, ease.out(rise));
  let squash = 1;
  let look = [Math.sin(T * 0.9) * 0.7, -0.2];
  if (t >= 7.4 && t < 9.0) {
    y += Math.sin((t - 7.4) * 4) * 3;
    squash = 1 + Math.sin((t - 7.4) * 8) * 0.04;
  }
  if (t >= 9.0) {
    const p = seg(t, 9.0, 10.9);
    const e = ease.in(p);
    x = TIP.x + e * 70 + Math.sin(p * Math.PI * 3) * 12;
    y = TIP.y - 44 - e * 240;
    squash = 1 + 0.08 * Math.sin(p * Math.PI * 4);
    look = [0.6, -0.8];
  }
  const ph = (T + 0.7) % 3.6;
  const blink = ph < 0.14 ? Math.sin((ph / 0.14) * Math.PI) : 0;
  return { x, y, r, squash, look, blink, face: clamp((rise - 0.55) / 0.3), smile: t > 7.6 && t < 10.4 };
}

function drawDot(ctx, pen, dot) {
  if (!dot) return;
  const { x, y, r, squash, look, blink, face, smile } = dot;
  ctx.globalAlpha = 1;
  ctx.save();
  ctx.translate(x, y);
  ctx.scale(1 / Math.sqrt(squash), Math.sqrt(squash));
  ctx.beginPath();
  ctx.arc(0, 0, r, 0, Math.PI * 2);
  ctx.fillStyle = pen.dot;
  ctx.fill();
  ctx.restore();
  ctx.save();
  ctx.translate(x, y);
  ctx.scale(1 / Math.sqrt(squash), Math.sqrt(squash));
  ctx.beginPath();
  ctx.arc(0, 0, r, 0, Math.PI * 2);
  ctx.restore();
  ctx.stroke();
  if (face <= 0) return;
  ctx.globalAlpha = face;
  ctx.fillStyle = pen.ink;
  const er = r * 0.09;
  const gap = r * 0.28;
  const ey = y - r * 0.12 + look[1] * r * 0.1;
  const ex = x + look[0] * r * 0.2;
  for (const s of [-1, 1]) {
    ctx.beginPath();
    ctx.ellipse(ex + s * gap, ey, er, Math.max(er * 1.2 * (1 - blink * 0.9), er * 0.15), 0, 0, Math.PI * 2);
    ctx.fill();
  }
  if (smile) {
    ctx.beginPath();
    ctx.arc(ex, ey + r * 0.16, r * 0.16, Math.PI * 0.2, Math.PI * 0.8);
    ctx.stroke();
  }
  ctx.globalAlpha = 1;
}

export function drawFrame(ctx, pen, t, T = t) {
  ctx.clearRect(0, 0, W, H);
  ctx.strokeStyle = pen.ink;
  ctx.lineWidth = LINE;
  ctx.lineCap = 'round';
  ctx.lineJoin = 'round';
  const hand = handAt(t);
  const seed = seedAt(t, hand);
  drawRoots(ctx, t);
  drawGround(ctx, pen, t);
  drawSeed(ctx, pen, seed, t);
  drawPlant(ctx, pen, t, T);
  drawClosingSoil(ctx, pen, t);
  drawDot(ctx, pen, dotAt(t, T));
  drawHand(ctx, pen, hand);
}

// The card's text colour is the ink, its background the paper, the account dot the resident.
export function penFor(el) {
  const style = getComputedStyle(el);
  let paper = 'rgb(255, 255, 255)';
  for (let node = el.parentElement; node; node = node.parentElement) {
    const bg = getComputedStyle(node).backgroundColor;
    if (bg && bg !== 'transparent' && !/rgba\(.*,\s*0\)$/.test(bg)) {
      paper = bg;
      break;
    }
  }
  const dot = style.getPropertyValue('--account-dot').trim() || '#f15d61';
  return { ink: style.color, paper, dot };
}
