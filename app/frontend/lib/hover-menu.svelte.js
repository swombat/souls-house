// Opens a dropdown menu when a mouse rests on its trigger, and closes it again
// when the mouse leaves both the trigger and the menu. Desktop only: a pointer
// that can hover (a mouse or trackpad) and a mouse event. Touch and pen never
// open on hover, so a phone keeps tap-to-open.
//
// A click on a hover-opened trigger pins the menu open (it then behaves as a
// clicked menu: Escape, a choice or a click outside close it). Keyboard focus
// stays where it was on a hover open and a hover close, so moving the mouse
// over the list doesn't pull focus into menus.
export const HOVER_QUERY = '(hover: hover) and (pointer: fine)';

function canHover(event) {
  if (event?.pointerType !== 'mouse') return false;
  if (typeof window === 'undefined' || typeof window.matchMedia !== 'function') return false;
  return window.matchMedia(HOVER_QUERY).matches;
}

export class HoverMenu {
  open = $state(false);
  viaHover = false;
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

  // On the trigger and on the menu content.
  enter = (event) => {
    if (!canHover(event)) return;
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
