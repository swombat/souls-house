// What voice mode does when the phone's screen goes off and comes back
// (jMapOj; Daniel on a Pixel with headphones, jNwAdJ enwVAx: "once the screen
// was switched off, it lost the connection").
//
// Two pieces, both plain browser plumbing so the panel can be tested with
// fakes:
//
// createWakeLock asks for a Screen Wake Lock while the panel is open, so the
// screen does not time out mid-conversation. The browser drops the lock
// whenever the page is hidden; it is asked for again when the page is visible.
// It cannot stop the person pressing the power button, and it does nothing
// where the API is missing (older iOS): both are fine, the pause below covers
// them.
//
// watchPage reports the page going to the back and coming to the front, the
// page being frozen or unloaded (pagehide), and the network coming back.
//
// What a web page cannot do: keep the microphone open with the screen locked.
// Chrome on Android may keep capturing a page that is hidden (it shows the mic
// notification) or may stop it; the page does not choose. So voice mode does
// not promise pocket mode: when the samples stop, it closes the open turn,
// says it is paused, and picks up again when the page is back.

export function createWakeLock({ nav = globalThis.navigator, doc = globalThis.document, onchange } = {}) {
  let sentinel = null;
  let wanted = false;
  let asking = null;

  const supported = () => Boolean(nav?.wakeLock?.request);

  async function acquire() {
    wanted = true;
    if (!supported() || sentinel || asking) return asking ?? Boolean(sentinel);
    if (doc?.visibilityState && doc.visibilityState !== 'visible') return false;
    asking = (async () => {
      try {
        const lock = await nav.wakeLock.request('screen');
        if (!wanted) {
          await lock.release?.().catch?.(() => {});
          return false;
        }
        sentinel = lock;
        lock.addEventListener?.('release', () => {
          if (sentinel === lock) sentinel = null;
          onchange?.(false);
        });
        onchange?.(true);
        return true;
      } catch {
        // refused (battery saver, no gesture yet, not allowed): not an error
        return false;
      } finally {
        asking = null;
      }
    })();
    return asking;
  }

  async function release() {
    wanted = false;
    const lock = sentinel;
    sentinel = null;
    try {
      await lock?.release?.();
    } catch {
      // already released
    }
  }

  return {
    acquire,
    release,
    get held() {
      return Boolean(sentinel);
    },
    get supported() {
      return supported();
    },
    // After the page is visible again, if the lock is still wanted.
    reacquire: () => (wanted ? acquire() : Promise.resolve(false)),
  };
}

export function watchPage({
  doc = globalThis.document,
  win = globalThis.window,
  onhidden,
  onvisible,
  onpagehide,
  ononline,
} = {}) {
  const visibility = () => {
    if (doc.visibilityState === 'hidden') onhidden?.();
    else onvisible?.();
  };
  const pagehide = () => onpagehide?.();
  const online = () => ononline?.();
  doc?.addEventListener?.('visibilitychange', visibility);
  win?.addEventListener?.('pagehide', pagehide);
  win?.addEventListener?.('online', online);
  return () => {
    doc?.removeEventListener?.('visibilitychange', visibility);
    win?.removeEventListener?.('pagehide', pagehide);
    win?.removeEventListener?.('online', online);
  };
}

export function pageVisible(doc = globalThis.document) {
  return !doc?.visibilityState || doc.visibilityState === 'visible';
}

export function online(nav = globalThis.navigator) {
  return nav?.onLine !== false;
}
