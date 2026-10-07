// Personal tint and account logo colour.
//
// The tint is one hue. application.css fixes lightness and scales chroma from --tint-c,
// so a hue can only ever produce a pale page in light mode and a deep, faint one in dark.
// Keep TINT_CHROMA in step with ApplicationHelper::TINT_CHROMA (server-rendered first paint).

export const TINT_CHROMA = 0.018;

// Named starting points; the slider allows any hue in between.
export const HUE_SWATCHES = [
  { name: 'Rose', hue: 355 },
  { name: 'Peach', hue: 45 },
  { name: 'Sand', hue: 85 },
  { name: 'Sage', hue: 145 },
  { name: 'Teal', hue: 195 },
  { name: 'Sky', hue: 240 },
  { name: 'Lavender', hue: 295 },
];

export function normaliseHue(value) {
  if (value === null || value === undefined || value === '') return null;
  const hue = Number(value);
  if (!Number.isInteger(hue) || hue < 0 || hue > 359) return null;
  return hue;
}

export function applyPersonalTint(root, value) {
  const hue = normaliseHue(value);
  if (hue === null) {
    root.style.removeProperty('--tint-h');
    root.style.removeProperty('--tint-c');
  } else {
    root.style.setProperty('--tint-h', String(hue));
    root.style.setProperty('--tint-c', String(TINT_CHROMA));
  }
}

export function applyAccountColour(root, colour) {
  if (colour) root.dataset.accountColour = colour;
  else delete root.dataset.accountColour;
}

// OKLCH -> sRGB hex, for places that cannot take a CSS variable (the browser chrome colour).
export function oklchToHex(l, c, h) {
  const rad = (h * Math.PI) / 180;
  const a = c * Math.cos(rad);
  const b = c * Math.sin(rad);
  const l_ = (l + 0.3963377774 * a + 0.2158037573 * b) ** 3;
  const m_ = (l - 0.1055613458 * a - 0.0638541728 * b) ** 3;
  const s_ = (l - 0.0894841775 * a - 1.291485548 * b) ** 3;
  const linear = [
    4.0767416621 * l_ - 3.3077115913 * m_ + 0.2309699292 * s_,
    -1.2684380046 * l_ + 2.6097574011 * m_ - 0.3413193965 * s_,
    -0.0041960863 * l_ - 0.7034186147 * m_ + 1.707614701 * s_,
  ];
  return (
    '#' +
    linear
      .map((v) => {
        const clamped = Math.min(1, Math.max(0, v));
        const srgb = clamped <= 0.0031308 ? 12.92 * clamped : 1.055 * clamped ** (1 / 2.4) - 0.055;
        return Math.round(srgb * 255)
          .toString(16)
          .padStart(2, '0');
      })
      .join('')
  );
}

// Matches --background in application.css for each mode.
export function browserChromeColours(value) {
  const hue = normaliseHue(value);
  if (hue === null) return { light: '#ffffff', dark: '#0a0a0a' };
  return {
    light: oklchToHex(1 - TINT_CHROMA * 1.2, TINT_CHROMA, hue),
    dark: oklchToHex(0.145, TINT_CHROMA, hue),
  };
}
