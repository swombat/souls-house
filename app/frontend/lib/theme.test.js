import { describe, expect, it } from 'vitest';
import {
  TINT_CHROMA,
  HUE_SWATCHES,
  normaliseHue,
  applyPersonalTint,
  applyAccountColour,
  oklchToHex,
  browserChromeColours,
} from './theme';
import { readFileSync } from 'node:fs';

const stylesheet = readFileSync('app/frontend/entrypoints/application.css', 'utf8');

function luminance(hex) {
  const channels = [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16) / 255);
  const linear = channels.map((v) => (v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4));
  return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2];
}

function contrast(a, b) {
  const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x);
  return (hi + 0.05) / (lo + 0.05);
}

const everyHue = Array.from({ length: 360 }, (_, hue) => hue);

describe('personal tint', () => {
  it('accepts whole degrees 0-359 and nothing else', () => {
    expect(normaliseHue(0)).toBe(0);
    expect(normaliseHue('359')).toBe(359);
    expect(normaliseHue(null)).toBeNull();
    expect(normaliseHue('')).toBeNull();
    expect(normaliseHue(360)).toBeNull();
    expect(normaliseHue(-1)).toBeNull();
    expect(normaliseHue(12.5)).toBeNull();
  });

  it('sets and removes the CSS variables on the root', () => {
    const root = document.createElement('html');
    applyPersonalTint(root, 355);
    expect(root.style.getPropertyValue('--tint-h')).toBe('355');
    expect(root.style.getPropertyValue('--tint-c')).toBe(String(TINT_CHROMA));
    applyPersonalTint(root, null);
    expect(root.style.getPropertyValue('--tint-h')).toBe('');
    expect(root.style.getPropertyValue('--tint-c')).toBe('');
  });

  it('swatches are valid hues', () => {
    for (const swatch of HUE_SWATCHES) expect(normaliseHue(swatch.hue)).toBe(swatch.hue);
  });

  it('keeps the untinted browser chrome colours exactly as before', () => {
    expect(browserChromeColours(null)).toEqual({ light: '#ffffff', dark: '#0a0a0a' });
    expect(oklchToHex(1, 0, 0)).toBe('#ffffff');
    expect(oklchToHex(0.145, 0, 0)).toBe('#0a0a0a');
  });

  // Mirrors the token formulas in application.css. No hue may make body or muted text
  // harder to read than it is on the untinted default.
  it('never lowers text contrast below the untinted default, at any hue', () => {
    const c = TINT_CHROMA;
    const light = {
      foreground: oklchToHex(0.145, 0, 0),
      mutedForeground: (tinted) => oklchToHex(tinted ? 0.556 - c * 2 : 0.556, 0, 0),
      background: (h) => oklchToHex(1 - c * 1.2, c, h),
      muted: (h) => oklchToHex(0.97 - c * 1.5, c * 1.5, h),
    };
    const dark = {
      mutedForeground: oklchToHex(0.708, 0, 0),
      background: (h) => oklchToHex(0.145, c, h),
      muted: (h) => oklchToHex(0.269, c * 1.2, h),
    };
    const baseline = {
      lightMutedOnBackground: contrast(light.mutedForeground(false), '#ffffff'),
      lightMutedOnMuted: contrast(light.mutedForeground(false), oklchToHex(0.97, 0, 0)),
      darkMutedOnBackground: contrast(dark.mutedForeground, oklchToHex(0.145, 0, 0)),
      darkMutedOnMuted: contrast(dark.mutedForeground, oklchToHex(0.269, 0, 0)),
    };
    // Dark tints keep lightness and text; allow rounding-level movement only.
    const slack = 0.1;
    for (const h of everyHue) {
      expect(contrast(light.mutedForeground(true), light.background(h))).toBeGreaterThanOrEqual(
        baseline.lightMutedOnBackground
      );
      expect(contrast(light.mutedForeground(true), light.muted(h))).toBeGreaterThanOrEqual(baseline.lightMutedOnMuted);
      expect(contrast(light.foreground, light.muted(h))).toBeGreaterThanOrEqual(7);
      expect(contrast(dark.mutedForeground, dark.background(h))).toBeGreaterThanOrEqual(
        baseline.darkMutedOnBackground - slack
      );
      expect(contrast(dark.mutedForeground, dark.muted(h))).toBeGreaterThanOrEqual(baseline.darkMutedOnMuted - slack);
    }
  });
});

describe('account logo colour', () => {
  it('sets and clears the data attribute', () => {
    const root = document.createElement('html');
    applyAccountColour(root, 'teal');
    expect(root.dataset.accountColour).toBe('teal');
    applyAccountColour(root, null);
    expect(root.dataset.accountColour).toBeUndefined();
  });

  // Read the dot colours straight from the stylesheet so this check cannot drift from it.
  // A graphic needs 3:1 against its background.
  function dotsFromCss() {
    const parse = (text) => text.split(/\s+/).map(Number);
    const dots = {};
    for (const [, name, value] of stylesheet.matchAll(
      /^\[data-account-colour=["'](\w+)["']\] \{\n\s+--account-dot: oklch\(([^)]+)\);/gm
    )) {
      dots[name] = [parse(value)];
    }
    for (const [, name, value] of stylesheet.matchAll(
      /^\.dark \[data-account-colour=["'](\w+)["']\] \{\n\s+--account-dot: oklch\(([^)]+)\);/gm
    )) {
      dots[name].push(parse(value));
    }
    return dots;
  }

  // The default coral has no attribute: it lives on :root as an OKLCH formula that is exactly
  // #f15d61 untinted and a touch darker under a tint. Dark mode keeps plain #f15d61.
  it('default coral is unchanged untinted and keeps 3:1 under every tint', () => {
    expect(stylesheet).toMatch(/--account-dot: oklch\(calc\(0\.6715 - var\(--tint-c\)\) 0\.1825 21\.87\);/);
    expect(stylesheet).toMatch(/\.dark \{\n {2}--account-dot: #f15d61;/);
    expect(oklchToHex(0.6715, 0.1825, 21.87)).toBe('#f15d61');
    const tinted = oklchToHex(0.6715 - TINT_CHROMA, 0.1825, 21.87);
    for (const h of everyHue) {
      const lightBg = oklchToHex(1 - TINT_CHROMA * 1.2, TINT_CHROMA, h);
      const darkBg = oklchToHex(0.145, TINT_CHROMA, h);
      expect(contrast(tinted, lightBg), `coral light @${h}`).toBeGreaterThanOrEqual(3);
      expect(contrast('#f15d61', darkBg), `coral dark @${h}`).toBeGreaterThanOrEqual(3);
    }
  });

  it('every dot stays visible against every tinted background in both modes', () => {
    const dots = dotsFromCss();
    expect(Object.keys(dots).length).toBeGreaterThanOrEqual(7);
    for (const [name, [lightDot, darkDot]] of Object.entries(dots)) {
      expect(darkDot, `${name} has a dark value`).toBeDefined();
      for (const h of everyHue) {
        const lightBg = oklchToHex(1 - TINT_CHROMA * 1.2, TINT_CHROMA, h);
        const darkBg = oklchToHex(0.145, TINT_CHROMA, h);
        expect(contrast(oklchToHex(...lightDot), lightBg), `${name} light @${h}`).toBeGreaterThanOrEqual(3);
        expect(contrast(oklchToHex(...darkDot), darkBg), `${name} dark @${h}`).toBeGreaterThanOrEqual(3);
      }
    }
  });
});
