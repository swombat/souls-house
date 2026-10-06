// Small timing helpers shared by the clips. Every clip is a pure function of `t` (seconds).
export const clamp = (x, a = 0, b = 1) => Math.min(b, Math.max(a, x));
export const ramp = (x, start, end) => clamp((x - start) / (end - start));
export const ease = (x) => (x < 0.5 ? 4 * x * x * x : 1 - Math.pow(-2 * x + 2, 3) / 2);
export const lerp = (a, b, x) => a + (b - a) * x;
export const typed = (text, t, start, end) => text.slice(0, Math.round(text.length * ramp(t, start, end)));
// Fade a whole clip in at the start and out at the end, so the loop seam is a soft blink.
export const loopFade = (t, duration) => ease(ramp(t, 0, 0.4)) * (1 - ease(ramp(t, duration - 0.6, duration)));
// An element arriving: opacity plus a short rise, as inline style.
export const arrive = (t, at, rise = 16, length = 0.45) => {
  const x = ease(ramp(t, at, at + length));
  return `opacity: ${x}; transform: translateY(${(1 - x) * rise}px);`;
};
