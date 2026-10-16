import { router } from '@inertiajs/svelte';

// A voice note lives only in the page's memory until it has been transcribed, so nothing may
// unload the page while one is being recorded or transcribed.
//
// The usual culprit is a deploy. Every Inertia request carries the asset version of the build
// that rendered the page; after a deploy the server answers an old version with a 409 and
// Inertia replaces the whole page. Inertia gives no way to refuse that once the 409 is back,
// and it can be any background refresh that triggers it (a message landing, a response
// finishing, the cable reconnecting). So while a recording is held:
// - background visits (router.reload, polls, prefetches: Inertia's async GETs) are not sent;
//   the props a refresh asked for are queued and reloaded once the last hold is released;
// - a visit the person starts themselves asks before leaving, since it discards the recording;
// - closing or reloading the tab asks first (beforeunload).
// A quiet hold ({ warn: false }) only holds background visits. The composer uses one between
// transcription and sending: the text is already saved as a draft, but the audio is attached
// only in memory, so a refresh should wait without making leaving the page a question.

export const LEAVE_WARNING = 'A voice note is still recording. Leaving this page will discard it.';

export function createRecordingGuard({
  router: inertia = router,
  win = typeof window === 'undefined' ? null : window,
} = {}) {
  let holds = 0;
  let warningHolds = 0;
  let stopListening = null;
  const queuedProps = new Set();
  let queuedEverything = false;

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
      if (visit.prefetch) return;
      const only = visit.only || [];
      if (only.length === 0) queuedEverything = true;
      only.forEach((prop) => queuedProps.add(prop));
      return;
    }

    if (!visit.async && warningHolds > 0 && !win?.confirm(LEAVE_WARNING)) event.preventDefault();
  }

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
    if (holds === 1) stopListening = inertia.on('before', onBeforeVisit);
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
      if (holds > 0) return;
      stopListening?.();
      stopListening = null;
      flush();
    };
  }

  return { hold, isHeld: () => holds > 0 };
}

const guard = createRecordingGuard();

// Returns a release function; call it once the recording has been transcribed or abandoned.
export const holdForRecording = guard.hold;
export const isRecordingHeld = guard.isHeld;
