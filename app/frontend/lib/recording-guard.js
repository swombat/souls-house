import { router } from '@inertiajs/svelte';
import axios from 'axios';

// A voice note lives only in the page's memory until it has been transcribed and sent, so
// nothing may unload the page in that time.
//
// The usual culprit is a deploy. Every Inertia request carries the asset version of the build
// that rendered the page; after a deploy the server answers a stale GET with a 409 and Inertia
// replaces the whole page. Any background refresh can trigger it (a message landing, a response
// finishing, the cable reconnecting). So while a recording is held:
// - background visits (router.reload, polls, prefetches: Inertia's async GETs) are not sent;
//   the props a refresh asked for are queued and reloaded once the last hold is released;
// - a refresh already in flight when the hold began can still come back as a 409; Inertia sends
//   through the shared axios instance, so an interceptor turns that response into a cancellation
//   (which Inertia ignores) and queues its props instead of letting Inertia reload the page.
//   Only background GETs are caught. A form POST that redirects (starting a new conversation)
//   keeps method 'post' in its axios config even though the 409 comes from the redirected GET;
//   the write has already happened, so cancelling it would leave the form waiting forever and
//   invite a duplicate on retry. A visit the person chose (and confirmed) passes through too;
// - a visit the person starts themselves asks before leaving, and so does closing or reloading
//   the tab (beforeunload).
// A quiet hold ({ warn: false }) holds refreshes without asking anything. The composers take one
// from transcription until the message is sent: the text is saved as a draft, but the audio is
// attached only in memory, and their own send must not be met with "discard the recording?".

export const LEAVE_WARNING = 'A voice note is still recording. Leaving this page will discard it.';

const header = (headers, name) => {
  if (!headers) return undefined;
  if (typeof headers.get === 'function') return headers.get(name);
  const key = Object.keys(headers).find((candidate) => candidate.toLowerCase() === name.toLowerCase());
  return key ? headers[key] : undefined;
};

export function isVersionConflict(error) {
  const response = error?.response;
  return response?.status === 409 && Boolean(header(response.headers, 'x-inertia-location'));
}

export function createRecordingGuard({
  router: inertia = router,
  http = axios,
  win = typeof window === 'undefined' ? null : window,
} = {}) {
  let holds = 0;
  let warningHolds = 0;
  const queuedProps = new Set();
  let queuedEverything = false;
  // A visit the person started while a hold was on; its 409 must reach Inertia, which then
  // loads the page they asked for.
  let personVisitInFlight = false;

  function queue(only) {
    if (!only || only.length === 0) queuedEverything = true;
    else only.forEach((prop) => queuedProps.add(prop));
  }

  const onBeforeUnload = (event) => {
    event.preventDefault();
    event.returnValue = LEAVE_WARNING;
    return LEAVE_WARNING;
  };

  function onBeforeVisit(event) {
    if (holds === 0) return;
    const visit = event.detail.visit;
    const method = String(visit.method || 'get').toLowerCase();

    if (visit.async && method === 'get') {
      event.preventDefault();
      if (!visit.prefetch) queue(visit.only);
      return;
    }

    if (!visit.async && warningHolds > 0 && !win?.confirm(LEAVE_WARNING)) {
      event.preventDefault();
      return;
    }
    if (!visit.async) personVisitInFlight = true;
  }

  function onFinishVisit(event) {
    if (!event?.detail?.visit?.async) personVisitInFlight = false;
  }

  function isBackgroundGet(config) {
    return String(config?.method || 'get').toLowerCase() === 'get' && !personVisitInFlight;
  }

  function onResponseError(error) {
    if (holds === 0 || !isVersionConflict(error) || !isBackgroundGet(error.config)) {
      return Promise.reject(error);
    }
    const partial = header(error.config?.headers, 'X-Inertia-Partial-Data');
    queue(partial ? String(partial).split(',').filter(Boolean) : []);
    return Promise.reject(new axios.CanceledError('Held while a voice note is recording'));
  }

  inertia.on?.('before', onBeforeVisit);
  inertia.on?.('finish', onFinishVisit);
  http?.interceptors?.response.use(undefined, onResponseError);

  function flush() {
    if (!queuedEverything && queuedProps.size === 0) return;
    const only = queuedEverything ? [] : Array.from(queuedProps);
    queuedProps.clear();
    queuedEverything = false;
    inertia.reload({
      ...(only.length ? { only } : {}),
      preserveState: true,
      preserveScroll: true,
      preserveUrl: true,
    });
  }

  function hold({ warn = true } = {}) {
    holds += 1;
    if (warn) {
      warningHolds += 1;
      if (warningHolds === 1) win?.addEventListener('beforeunload', onBeforeUnload);
    }
    let released = false;
    return function release() {
      if (released) return;
      released = true;
      if (warn) {
        warningHolds -= 1;
        if (warningHolds === 0) win?.removeEventListener('beforeunload', onBeforeUnload);
      }
      holds -= 1;
      if (holds === 0) flush();
    };
  }

  return { hold, isHeld: () => holds > 0 };
}

const guard = createRecordingGuard();

// Returns a release function; call it once the recording has been transcribed and sent, or
// abandoned. Releasing twice is harmless.
export const holdForRecording = guard.hold;
export const isRecordingHeld = guard.isHeld;
