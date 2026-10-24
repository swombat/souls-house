import { toast } from 'svelte-sonner';

// The layouts toast the server's flash whenever the Inertia page changes. A
// partial reload (router.reload({ only: [...] }), the cable refreshes) merges
// its props over the current page's, so the old flash object rides along
// unchanged and every refresh would toast it again. Toast each flash object
// once: a fresh visit brings a fresh object, a merged reload brings the same one.
const shown = new WeakSet();

export function showFlashToasts(flash, notify = toast) {
  if (!flash || typeof flash !== 'object' || shown.has(flash)) return;
  shown.add(flash);

  if (flash.notice) notify.success(flash.notice);
  if (flash.alert) notify.error(flash.alert);
}
