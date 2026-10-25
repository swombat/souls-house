// Stripe.js, loaded only on the page that takes a payment, and only once.
// The card form and any bank check (3-D Secure) are Stripe's own iframes;
// card details never pass through the house.
// Pinned to the release matching the house's Stripe API version
// (2026-09-30.endive): that release mounts ui_mode embedded_page sessions.
const SRC = 'https://js.stripe.com/endive/stripe.js';
let loading = null;

export function loadStripe(publishableKey) {
  if (!publishableKey) return Promise.reject(new Error('Stripe is not configured on this house.'));
  if (typeof window !== 'undefined' && window.Stripe) return Promise.resolve(window.Stripe(publishableKey));

  loading ||= new Promise((resolve, reject) => {
    const script = document.createElement('script');
    script.src = SRC;
    script.async = true;
    script.onload = () => resolve();
    script.onerror = () => {
      loading = null;
      reject(new Error("Stripe's payment form couldn't be loaded. Check your connection and try again."));
    };
    document.head.appendChild(script);
  });
  return loading.then(() => window.Stripe(publishableKey));
}

// POST JSON with the page's CSRF token; returns the parsed body, or throws
// an Error carrying the server's own message.
export async function postJson(url, body = {}) {
  const token = document.querySelector('meta[name="csrf-token"]')?.content;
  const response = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Accept: 'application/json', 'X-CSRF-Token': token || '' },
    credentials: 'same-origin',
    body: JSON.stringify(body),
  });
  const data = await response.json().catch(() => ({}));
  if (!response.ok) {
    const error = new Error(data.error || 'Something went wrong. Please try again.');
    error.data = data;
    throw error;
  }
  return data;
}

// Mounts Stripe's embedded Checkout page. Newer Stripe.js releases name it
// createEmbeddedCheckoutPage; older ones initEmbeddedCheckout.
export function createEmbeddedCheckout(stripe, options) {
  if (typeof stripe.createEmbeddedCheckoutPage === 'function') return stripe.createEmbeddedCheckoutPage(options);
  return stripe.initEmbeddedCheckout(options);
}
