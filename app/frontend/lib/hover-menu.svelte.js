// Opens a dropdown menu when a mouse moves onto its trigger and rests there, and closes it again
// when the mouse leaves both the trigger and the menu. Desktop only: a pointer
// that can hover (a mouse or trackpad) and a mouse event. Touch and pen never
// open on hover, so a phone keeps tap-to-open.
//
// A click on a hover-opened trigger pins the menu open (it then behaves as a
// clicked menu: Escape, a choice or a click outside close it). Keyboard focus
// stays where it was on a hover open and a hover close, so moving the mouse
// over the list doesn't pull focus into menus.
//
// A hover-opened menu must not lock the page: bits-ui's scroll lock sets
// pointer-events: none on <body>, so the trigger stops being under the mouse,
// the next small move reads as leaving, and the menu flickers shut and open.
// Pass `preventScroll={!menu.viaHover}` to the menu content.
export const HOVER_QUERY = '(hover: hover) and (pointer: fine)';

function canHover(event) {
  if (event?.pointerType !== 'mouse') return false;
  if (typeof window === 'undefined' || typeof window.matchMedia !== 'function') return false;
  return window.matchMedia(HOVER_QUERY).matches;
}

export class HoverMenu {
  open = $state(false);
  // Reactive: the menu content reads it to skip the page-wide scroll lock.
  viaHover = $state(false);
  #closingViaHover = false;
  #openTimer = null;
  #closeTimer = null;
  #openDelay;
  #closeDelay;

  constructor({ openDelay = 120, closeDelay = 250 } = {}) {
    this.#openDelay = openDelay;
    this.#closeDelay = closeDelay;
  }

  #clear() {
    clearTimeout(this.#openTimer);
    clearTimeout(this.#closeTimer);
    this.#openTimer = null;
    this.#closeTimer = null;
  }

  // On the trigger and on the menu content: the mouse is back, so a pending
  // hover close is cancelled. Arriving alone never opens a menu: a drawer or
  // list can slide a trigger under a mouse that hasn't moved, and that must
  // not pop a menu over whatever the person was about to click.
  enter = (event) => {
    if (!canHover(event)) return;
    clearTimeout(this.#closeTimer);
    this.#closeTimer = null;
  };

  // On the trigger: a real movement of the mouse over it starts the open timer.
  move = (event) => {
    if (!canHover(event)) return;
    if (!event.movementX && !event.movementY) return; // synthetic, layout-driven
    clearTimeout(this.#closeTimer);
    this.#closeTimer = null;
    if (this.open || this.#openTimer) return;
    this.#openTimer = setTimeout(() => {
      this.#openTimer = null;
      this.viaHover = true;
      this.open = true;
    }, this.#openDelay);
  };

  leave = (event) => {
    if (event?.pointerType !== 'mouse') return;
    clearTimeout(this.#openTimer);
    this.#openTimer = null;
    if (!this.open || !this.viaHover) return;
    clearTimeout(this.#closeTimer);
    this.#closeTimer = setTimeout(() => {
      this.#closeTimer = null;
      this.#closingViaHover = true;
      this.open = false;
      this.viaHover = false;
    }, this.#closeDelay);
  };

  // On the trigger, before the menu's own toggle: a click on a menu the hover
  // already opened keeps it open instead of closing it under the mouse.
  pointerdown = (event) => {
    clearTimeout(this.#openTimer);
    this.#openTimer = null;
    if (!this.open || !this.viaHover || event.button !== 0) return;
    this.#clear();
    this.viaHover = false;
    event.preventDefault();
  };

  // The menu's own open changes (click, keyboard, Escape, choice, outside click).
  openChange = (value) => {
    if (value) return;
    // A choice made in a hover-opened menu doesn't send focus to the button either.
    if (this.viaHover) this.#closingViaHover = true;
    this.#clear();
    this.viaHover = false;
  };

  openAutoFocus = (event) => {
    if (this.viaHover) event.preventDefault();
  };

  closeAutoFocus = (event) => {
    if (this.#closingViaHover) event.preventDefault();
    this.#closingViaHover = false;
  };

  destroy() {
    this.#clear();
  }
}
