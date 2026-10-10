import { createConsumer } from '@rails/actioncable';
import { router } from '@inertiajs/svelte';
import * as logging from '$lib/logging';

// Check if we're in browser environment
const browser = typeof window !== 'undefined';

// Create consumer once
const consumer = browser ? createConsumer() : null;

// Pure debounce function
export function debounce(fn, delay) {
  let timeoutId;
  let pendingProps = new Set();

  return (props) => {
    // Accumulate props
    props.forEach((prop) => pendingProps.add(prop));

    clearTimeout(timeoutId);
    timeoutId = setTimeout(() => {
      if (pendingProps.size > 0) {
        fn(Array.from(pendingProps));
        pendingProps.clear();
      }
    }, delay);
  };
}

// A background refresh is an async Inertia visit to the URL that was current when it was sent.
// Inertia 2 still applies it if the user has navigated meanwhile, as long as the pathname
// matches. It ignores the query string, takes the response's (stale) URL and pushes a history
// entry for it. On /admin/accounts that quietly undid an account selection whenever any account
// changed while the admin was clicking. So a refresh never moves the URL; a refresh still in
// flight when a navigation starts (a visit or the browser's back/forward) is cancelled and
// re-queued; and no refresh is sent while a visit is in flight, because the URL it would read is
// about to stop being true.
export function backgroundReloadOptions(props) {
  return { only: props, preserveState: true, preserveScroll: true, preserveUrl: true };
}

const inFlightRefreshes = new Set();
const deferredProps = new Set();
let navigating = 0;
let navigationStartedAt = 0;
// If a visit never reports finishing, stop deferring refreshes after this long rather than forever.
const NAVIGATION_GRACE_MS = 10_000;
const isNavigating = () => navigating > 0 && Date.now() - navigationStartedAt < NAVIGATION_GRACE_MS;

function flushDeferred() {
  if (isNavigating() || deferredProps.size === 0) return;
  const props = Array.from(deferredProps);
  deferredProps.clear();
  reloadProps(props);
}

const cancelRefreshes = () => inFlightRefreshes.forEach((refresh) => refresh.cancel());

if (browser) {
  router.on('before', (event) => {
    if (event.detail.visit.async) return;
    cancelRefreshes();
  });
  router.on('start', (event) => {
    if (event.detail.visit.async) return;
    navigating += 1;
    navigationStartedAt = Date.now();
  });
  router.on('finish', (event) => {
    if (event.detail.visit.async) return;
    navigating = Math.max(0, navigating - 1);
    if (navigating === 0) flushDeferred();
  });
  window.addEventListener('popstate', cancelRefreshes);
}

// Global debounced reload (shared across all subscriptions)
export const reloadProps = debounce((props) => {
  if (isNavigating()) {
    props.forEach((prop) => deferredProps.add(prop));
    setTimeout(flushDeferred, NAVIGATION_GRACE_MS);
    return;
  }
  logging.debug('Reloading props:', props);
  let refresh = null;
  router.reload({
    ...backgroundReloadOptions(props),
    onCancelToken: (token) => {
      refresh = token;
      inFlightRefreshes.add(token);
    },
    onCancel: () => reloadProps(props),
    onFinish: () => inFlightRefreshes.delete(refresh),
  });
}, 300);

/**
 * Internal function to subscribe to model updates
 * @private
 */
export function subscribeToModel(model, id, props) {
  if (!browser || !consumer) return () => {};

  const subscription = consumer.subscriptions.create(
    {
      channel: 'SyncChannel',
      model,
      id,
    },
    {
      connected() {
        logging.debug(`Sync connected: ${model}:${id}`);
        if (model === 'Chat' || model === 'Account' || model === 'ReplyAttention' || model === 'FieldRecording') {
          // Broadcasts are not replayed. Catch up changes missed before the
          // subscription or during a disconnect, without needing another change.
          // A FieldRecording that finished transcribing meanwhile would
          // otherwise sit on "Transcribing…" until a manual refresh.
          reloadProps(props);
          if (model === 'Chat') {
            window.dispatchEvent(new CustomEvent('runtime-activity-refresh'));
            // Older loaded history is not part of that reload (chat-history.svelte.js).
            window.dispatchEvent(new CustomEvent('chat-sync-connected', { detail: { id } }));
          }
        }
      },

      received(data) {
        logging.debug(`Sync received: ${model}:${id}`, data);
        if (data.action === 'runtime_activity_changed') {
          window.dispatchEvent(new CustomEvent('runtime-activity-refresh'));
          return;
        }

        // Handle streaming updates specially - don't reload, just update in place
        if (handleStreamingUpdate(data)) {
          return;
        }

        // A resident's handoff receipt moved: patched in place by the room's
        // history, which also reaches older messages a reload would miss.
        if (data.action === 'handoff_receipts') {
          if (browser) window.dispatchEvent(new CustomEvent('handoff-receipts', { detail: data }));
          return;
        }

        // Use explicit prop from server or fallback to provided props
        // const propsToReload = data.prop ? [data.prop] : props;
        reloadProps(props);
      },

      disconnected() {
        logging.debug(`Sync disconnected: ${model}:${id}`);
      },
    }
  );

  return () => subscription.unsubscribe();
}

export function streamingEventName(data) {
  if (
    data.action === 'streaming_update' ||
    data.action === 'thinking_update' ||
    data.action === 'error' ||
    data.action === 'agent_skipped'
  ) {
    return 'streaming-update';
  }

  if (data.action === 'streaming_end') {
    return 'streaming-end';
  }

  if (data.action === 'debug_log') {
    return 'debug-log';
  }

  return null;
}

function handleStreamingUpdate(data) {
  const eventName = streamingEventName(data);

  if (eventName) {
    // Dispatch a custom event that the chat component can listen to
    if (browser) {
      window.dispatchEvent(new CustomEvent(eventName, { detail: data }));
    }
    return true;
  }
}
