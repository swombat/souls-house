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

// Global debounced reload (shared across all subscriptions)
const reloadProps = debounce((props) => {
  logging.debug('Reloading props:', props);
  router.reload({
    only: props,
    preserveState: true,
    preserveScroll: true,
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
      },

      received(data) {
        logging.debug(`Sync received: ${model}:${id}`, data);

        // Handle streaming updates specially - don't reload, just update in place
        if (handleStreamingUpdate(data)) {
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
