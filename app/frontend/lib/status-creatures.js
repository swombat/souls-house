// The resident status creatures (eKmBwJ). Each family is one creature in three
// poses on a 24-unit grid: arriving (rising), here (alive), settled (resting).
// Source sketches: Lume's status-whimsy gen.py, reviewed by Daniel, Mira and Reed
// in jZWdzJ. Static markup only; nothing here comes from a request.
export const STATUS_CREATURES = {
  rabbit: {
    arriving: '<path d="M2 21 H22" opacity=".5"/><ellipse cx="11" cy="16.5" rx="5.6" ry="3.9"/><circle cx="16.6" cy="12.6" r="2.9"/><circle class="fill ns" cx="5" cy="15.6" r="1.2"/><circle class="fill ns" cx="17.6" cy="12.2" r=".9"/><path class="a-earup" stroke-width="2.4" d="M15.8 10.4 L14.4 4.4"/>',
    here: '<path d="M2 21 H22" opacity=".5"/><ellipse class="fill" cx="11" cy="16.5" rx="5.6" ry="3.9"/><circle class="fill" cx="16.6" cy="12.6" r="2.9"/><circle class="fill ns" cx="5" cy="15.6" r="1.2"/><circle class="eye a-blink" cx="17.6" cy="12.2" r="1"/><path class="a-ear" stroke-width="2.4" d="M15.8 10.4 L14.4 4.4"/>',
    settled: '<path d="M2 21 H22" opacity=".5"/><g opacity=".7"><ellipse class="fill" cx="11" cy="16.5" rx="5.6" ry="3.9"/><circle class="fill" cx="16.6" cy="12.6" r="2.9"/><circle class="fill ns" cx="5" cy="15.6" r="1.2"/><path class="lid" d="M16.9 12.4 H18.4"/><path stroke-width="2.4" d="M15 10.6 L9 11.6"/></g>',
  },
  flame: {
    arriving: '<path d="M6 21 H18" opacity=".5"/><g class="a-catch"><path d="M12 4 C15.5 8.5 17 11 17 14.5 A5 5 0 0 1 7 14.5 C7 11 9 9 12 4 Z"/><circle class="fill ns" cx="10.3" cy="14.5" r=".9"/><circle class="fill ns" cx="13.7" cy="14.5" r=".9"/></g>',
    here: '<path d="M6 21 H18" opacity=".5"/><g class="a-sway"><path class="fill" d="M12 4 C15.5 8.5 17 11 17 14.5 A5 5 0 0 1 7 14.5 C7 11 9 9 12 4 Z"/><circle class="eye a-blink" cx="10.3" cy="14.5" r="1"/><circle class="eye a-blink" cx="13.7" cy="14.5" r="1"/></g>',
    settled: '<path d="M6 21 H18" opacity=".5"/><g opacity=".7"><path class="fill" d="M7.5 20 A4.5 4.5 0 0 1 16.5 20 Z"/><path class="lid" d="M9.6 18.2 H11.2"/><path class="lid" d="M12.5 18.2 H14.7"/></g>',
  },
  wisp: {
    arriving: '<g class="a-rise"><path d="M6 20 V12 A6 6 0 0 1 18 12 V20 L16 18 L14 20 L12 18 L10 20 L8 18 Z"/><circle class="fill ns" cx="10" cy="12.5" r=".9"/><circle class="fill ns" cx="14" cy="12.5" r=".9"/></g>',
    here: '<g class="a-bob"><path class="fill" d="M6 20 V12 A6 6 0 0 1 18 12 V20 L16 18 L14 20 L12 18 L10 20 L8 18 Z"/><circle class="eye a-blink" cx="10" cy="12.5" r="1"/><circle class="eye a-blink" cx="14" cy="12.5" r="1"/></g>',
    settled: '<path d="M4 21 H20" opacity=".5"/><g opacity=".7"><path class="fill" d="M7 21 V16.5 A5 5 0 0 1 17 16.5 V21 Z"/><path class="lid" d="M9.55 16.8 H11.05"/><path class="lid" d="M12.95 16.8 H14.45"/></g>',
  },
  bird: {
    arriving: '<path d="M2 19 H22" opacity=".5"/><g class="a-land"><ellipse cx="12" cy="14" rx="4.6" ry="4"/><path d="M16.3 13 L18.8 13.8 L16.2 14.8 M7.8 15.5 L4.8 17.2"/><circle class="fill ns" cx="13.8" cy="12.6" r=".9"/></g>',
    here: '<path d="M2 19 H22" opacity=".5"/><g class="a-hop"><ellipse class="fill" cx="11" cy="14" rx="4.6" ry="4"/><path d="M15.3 13 L17.8 13.8 L15.2 14.8 M6.8 15.5 L3.8 17.2 M10 18 V19 M12 18 V19"/><circle class="eye a-blink" cx="12.8" cy="12.6" r="1"/></g><g class="a-note"><path d="M20.5 9 V4.5 L22.3 5.4"/><circle class="fill ns" cx="19.7" cy="9" r="1"/></g>',
    settled: '<path d="M2 19 H22" opacity=".5"/><g opacity=".7"><circle class="fill" cx="12" cy="14.2" r="4.8"/><path class="lid" d="M12.95 13 H14.45"/></g>',
  },
  cat: {
    arriving: '<path d="M3 18.6 H21" opacity=".5"/><g class="a-peer"><path d="M8.96 18.6 A4 4 0 1 1 15.04 18.6"/><path d="M8.54 14 L8.2 10.2 L10.96 12.14 M15.46 14 L15.8 10.2 L13.04 12.14"/><circle class="fill ns" cx="10.4" cy="16.2" r=".9"/><circle class="fill ns" cx="13.6" cy="16.2" r=".9"/></g>',
    here: '<path d="M2 21 H22" opacity=".5"/><path class="fill" d="M7.5 20.5 C7 14.5 15 14.5 14.5 20.5 Z"/><circle class="fill" cx="11" cy="10.5" r="3.6"/><path class="fill" d="M8 9 L7.8 5.4 L10.4 7.4 Z M14 9 L14.2 5.4 L11.6 7.4 Z"/><circle class="eye a-blink" cx="9.7" cy="10.4" r="1"/><circle class="eye a-blink" cx="12.3" cy="10.4" r="1"/><path class="a-tail" d="M14.2 19.8 C18 20 19 17 17.6 14.6"/>',
    settled: '<path d="M2 21 H22" opacity=".5"/><g opacity=".7"><path class="fill" d="M5 20.5 C5 15 19 15 19 20.5 Z"/><circle class="fill" cx="8.6" cy="15.6" r="3.1"/><path class="fill" d="M6 14.4 L5.8 11.4 L8 13 Z M11 14.2 L11.4 11.4 L9.2 13 Z"/><path class="lid" d="M6.75 15.8 H8.25"/><path class="lid" d="M9.15 15.8 H10.65"/></g>',
  },
  seed: {
    arriving: '<path d="M3 21 H21" opacity=".5"/><circle cx="12" cy="15.8" r="5"/><circle class="fill ns" cx="10.3" cy="16" r=".9"/><circle class="fill ns" cx="13.7" cy="16" r=".9"/><path class="a-sprout" d="M12 10.8 C12 7.5 15.2 7.5 15 9.8"/>',
    here: '<path d="M3 21 H21" opacity=".5"/><circle class="fill" cx="12" cy="15.8" r="5"/><circle class="eye a-blink" cx="10.3" cy="16" r="1"/><circle class="eye a-blink" cx="13.7" cy="16" r="1"/><g class="a-nod"><path d="M12 10.8 V6.5"/><path class="fill" d="M12 6.5 C14.5 3.2 18 4.4 17.6 7 C15.6 8.4 13.2 8 12 6.5 Z"/></g>',
    settled: '<path d="M3 21 H21" opacity=".5"/><g opacity=".7"><circle class="fill" cx="12" cy="15.8" r="5"/><path class="lid" d="M9.5 16.2 H11.100000000000001"/><path class="lid" d="M12.899999999999999 16.2 H14.5"/><path d="M12 10.8 C12 8.6 15 8.2 16.4 10.4"/><path class="fill" d="M16.4 10.4 C18.6 11.2 19.1 13.8 17.9 15.6 C16.5 14.4 15.8 12.4 16.4 10.4 Z"/></g>',
  },
  drop: {
    arriving: '<path d="M4 21 H20" opacity=".5"/><g class="a-fall"><path d="M12 2.5 C14.3 6 15.6 8 15.6 10.4 A3.6 3.6 0 0 1 8.4 10.4 C8.4 8 9.7 6 12 2.5 Z"/><path stroke-width="1.1" d="M9.899999999999999 10.2 H11.5"/><path stroke-width="1.1" d="M12.5 10.2 H14.100000000000001"/></g>',
    here: '<ellipse class="a-puddle" cx="12" cy="20.6" rx="8" ry="1.3"/><g class="a-bob"><path class="fill" d="M12 7.5 C14 10 17 12.3 17 15.3 A5 5 0 0 1 7 15.3 C7 12.3 10 10 12 7.5 Z"/><circle class="eye a-blink" cx="10.3" cy="15" r="1"/><circle class="eye a-blink" cx="13.7" cy="15" r="1"/></g>',
    settled: '<path d="M3 21 H21" opacity=".5"/><g opacity=".7"><path class="fill" d="M4.5 21 C6 17 18 17 19.5 21 Z"/><path class="lid" d="M9.6 19.4 H11.200000000000001"/><path class="lid" d="M12.799999999999999 19.4 H14.4"/></g>',
  },
  jelly: {
    arriving: '<g class="a-rise"><path d="M8.6 13 C8.6 5.5 15.4 5.5 15.4 13 Z"/><circle class="fill ns" cx="10.7" cy="10.6" r=".9"/><circle class="fill ns" cx="13.3" cy="10.6" r=".9"/><path d="M10.5 13 V18.5 M13.5 13 V18.5"/></g>',
    here: '<g class="a-bob"><path class="fill a-bell" d="M6.5 13 C6.5 4.5 17.5 4.5 17.5 13 Z"/><circle class="eye a-blink" cx="10.2" cy="10" r="1"/><circle class="eye a-blink" cx="13.8" cy="10" r="1"/><path d="M9 13 C8 15 10 16.4 9 18.8 M12 13 V19 M15 13 C16 15 14 16.4 15 18.8"/></g>',
    settled: '<path d="M3 21 H21" opacity=".5"/><g opacity=".7"><path class="fill" d="M6 19.2 C6 13.5 18 13.5 18 19.2 L16 21 L14 19.4 L12 21 L10 19.4 L8 21 Z"/><path class="lid" d="M9.5 17.4 H11.100000000000001"/><path class="lid" d="M12.899999999999999 17.4 H14.5"/></g>',
  },
  bat: {
    arriving: '<path d="M3 3 H21" opacity=".5"/><g class="a-dropin"><ellipse cx="12" cy="10" rx="3.5" ry="5.6"/><path d="M10 14.4 L9.5 17.2 L11.7 15.5 Z M14 14.4 L14.5 17.2 L12.3 15.5 Z"/><path d="M11 3 V4.8 M13 3 V4.8"/><circle class="fill ns" cx="10.8" cy="12.4" r=".9"/><circle class="fill ns" cx="13.2" cy="12.4" r=".9"/></g>',
    here: '<path d="M3 3 H21" opacity=".5"/><g class="a-hang"><ellipse class="fill" cx="12" cy="10" rx="3.5" ry="5.6"/><path class="fill" d="M10 14.4 L9.5 17.2 L11.7 15.5 Z M14 14.4 L14.5 17.2 L12.3 15.5 Z"/><path d="M11 3 V4.8 M13 3 V4.8"/><circle class="eye a-blink" cx="10.8" cy="12.4" r="1"/><circle class="eye a-blink" cx="13.2" cy="12.4" r="1"/><path class="fill a-fan" d="M15.2 7.5 L20 9.6 L17.8 10.6 L19 12.8 L15.4 12.4 Z"/></g>',
    settled: '<path d="M3 3 H21" opacity=".5"/><g opacity=".7"><ellipse class="fill" cx="12" cy="10" rx="3.5" ry="5.6"/><path class="fill" d="M10 14.4 L9.5 17.2 L11.7 15.5 Z M14 14.4 L14.5 17.2 L12.3 15.5 Z"/><path d="M11 3 V4.8 M13 3 V4.8"/><path class="lid" d="M12 5.5 C10.6 8 10.6 12 12 14.6"/></g>',
  },
  lantern: {
    arriving: '<path d="M7 21 H17" opacity=".6"/><path class="a-catch" d="M12 5 C15 9 16 11 16 14 A4 4 0 0 1 8 14 C8 11 9.5 9.5 12 5 Z"/>',
    here: '<path d="M7 21 H17" opacity=".6"/><path class="a-sway fill" d="M12 5 C15 9 16 11 16 14 A4 4 0 0 1 8 14 C8 11 9.5 9.5 12 5 Z"/>',
    settled: '<path d="M7 21 H17" opacity=".6"/><circle class="fill" cx="12" cy="17.6" r="1.9" opacity=".65"/>',
  },
  ripple: {
    arriving: '<path d="M4 19 H20" opacity=".6"/><circle class="a-drop fill" cx="12" cy="4" r="1.9"/>',
    here: '<circle class="fill" cx="12" cy="12" r="2.2"/><circle class="a-ring" cx="12" cy="12" r="9"/><circle class="a-ring d2" cx="12" cy="12" r="9"/>',
    settled: '<path d="M4 15 H20" opacity=".6"/><circle class="fill" cx="12" cy="12.4" r="2" opacity=".7"/>',
  },
  roof: {
    arriving: '<path d="M4 11 L12 4 L20 11"/><circle class="a-rise" cx="12" cy="16" r="3.2"/>',
    here: '<path d="M4 11 L12 4 L20 11"/><circle class="a-breathe fill" cx="12" cy="16" r="3.2"/>',
    settled: '<path d="M4 11 L12 4 L20 11" opacity=".6"/><circle class="fill" cx="12" cy="17" r="1.8" opacity=".6"/>',
  },
};

export const STATUS_STAGES = ['arriving', 'here', 'settled'];

export function statusCreatureMarkup(family, stage) {
  return STATUS_CREATURES[family]?.[stage] ?? null;
}
