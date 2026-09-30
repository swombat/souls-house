import { onMount, onDestroy } from 'svelte';
import { subscribeToModel } from './cable';
import * as logging from '$lib/logging';

/**
 * Hook to synchronize Svelte components with Rails models via ActionCable
 *
 * @param {Object} subscriptions - Map of subscriptions
 * @example
 * useSync({
 *   'Account:abc123': 'account',
 *   'Account:all': 'accounts',
 *   'Account:abc123/account_users': 'account'
 * })
 */
export function useSync(subscriptions) {
  const unsubscribers = [];

  onMount(() => {
    Object.entries(subscriptions).forEach(([key, prop]) => {
      // Parse the subscription key
      const match = key.match(/^([A-Z]\w+):([^\/]+)(\/.*)?$/);
      if (!match) {
        logging.warn(`Invalid subscription key: ${key}`);
        return;
      }

      const [, model, id, collection] = match;
      const props = Array.isArray(prop) ? prop : [prop];

      // Create subscription
      logging.debug('Creating subscription for', model, id, props);
      const unsubscribe = subscribeToModel(model, id, props);
      unsubscribers.push(unsubscribe);

      // If there's a collection suffix, subscribe to that too
      if (collection) {
        // This handles cases like 'Account:abc123/account_users'
        // The broadcast will still come on 'Account:abc123' channel
        // but we know to reload the specified prop
      }
    });
  });

  onDestroy(() => {
    unsubscribers.forEach((unsub) => unsub());
  });
}

/**
 * Create sync subscriptions that can be managed dynamically
 * Returns a function to update subscriptions
 *
 * @example
 * const updateSync = createDynamicSync();
 *
 * $effect(() => {
 *   const subs = { 'Account:all': 'accounts' };
 *   if (selected) subs[`Account:${selected.id}`] = 'selected';
 *   updateSync(subs);
 * });
 */
export function createDynamicSync() {
  let currentUnsubscribers = [];

  // Clean up all subscriptions when component is destroyed
  onDestroy(() => {
    currentUnsubscribers.forEach((unsub) => unsub());
    currentUnsubscribers = [];
  });

  // Return a function that can be called to update subscriptions
  return (subscriptions) => {
    // Clean up old subscriptions
    currentUnsubscribers.forEach((unsub) => unsub());
    currentUnsubscribers = [];

    // Create new subscriptions
    Object.entries(subscriptions).forEach(([key, prop]) => {
      // Parse the subscription key
      const match = key.match(/^([A-Z]\w+):([^\/]+)(\/.*)?$/);
      if (!match) {
        logging.warn(`Invalid subscription key: ${key}`);
        return;
      }

      const [, model, id, collection] = match;
      const props = Array.isArray(prop) ? prop : [prop];

      // Create subscription
      logging.debug('Creating dynamic subscription for', model, id, props);
      const unsubscribe = subscribeToModel(model, id, props);
      currentUnsubscribers.push(unsubscribe);
    });
  };
}
