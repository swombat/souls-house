import { writable } from 'svelte/store';
import Link from './MockLink.svelte';

// Export the Link component for tests
export { Link };

// IMPORTANT: This is NOT a mock! This adapter makes REAL HTTP requests to the Rails backend.
// NEVER mock the backend in tests - all tests must hit the real Rails API.
// Run tests with: bun run test:integrated (which starts Rails automatically)
export const useForm = (initialData = {}) => {
  // Create the reactive store with form data
  const store = writable({
    ...initialData,
    errors: {},
    processing: false,
    progress: null,
    wasSuccessful: false,
    recentlySuccessful: false,
  });

  // Create the form object that acts like Inertia's form
  const form = {
    // Make it subscribable like a Svelte store
    subscribe: (fn) => {
      // When subscribing, pass an object that has both the data and the methods
      return store.subscribe((value) => {
        const formWithMethods = {
          ...value,
          post: async (url, options = {}) => {
            return form.submit('POST', url, options);
          },
          put: async (url, options = {}) => {
            return form.submit('PUT', url, options);
          },
          patch: async (url, options = {}) => {
            return form.submit('PATCH', url, options);
          },
          delete: async (url, options = {}) => {
            return form.submit('DELETE', url, options);
          },
          get: async (url, options = {}) => {
            return form.submit('GET', url, options);
          },
        };
        fn(formWithMethods);
      });
    },
    set: store.set,
    update: store.update,

    // Form submission methods that actually make HTTP requests
    post: async (url, options = {}) => {
      return form.submit('POST', url, options);
    },

    put: async (url, options = {}) => {
      return form.submit('PUT', url, options);
    },

    patch: async (url, options = {}) => {
      return form.submit('PATCH', url, options);
    },

    delete: async (url, options = {}) => {
      return form.submit('DELETE', url, options);
    },

    get: async (url, options = {}) => {
      return form.submit('GET', url, options);
    },

    submit: async (method, url, options = {}) => {
      // Get current form data
      let currentData;
      store.subscribe((value) => (currentData = value))();

      // Extract only the actual form fields (not the state fields)
      const { errors, processing, progress, wasSuccessful, recentlySuccessful, ...formFields } = currentData;

      // Set processing state
      store.update((f) => ({ ...f, processing: true, errors: {} }));

      try {
        // Make the actual HTTP request
        // When testing with real backend, the Playwright dev server should proxy to Rails
        const response = await fetch(url, {
          method: method,
          headers: {
            'Content-Type': 'application/json',
            'X-Inertia': 'true',
            'X-Requested-With': 'XMLHttpRequest',
            Accept: 'application/json',
          },
          credentials: 'include', // Include cookies for session management
          body: method !== 'GET' ? JSON.stringify(formFields) : undefined,
        });

        let responseData = {};

        // Handle different response types
        if (response.headers.get('content-type')?.includes('application/json')) {
          try {
            responseData = await response.json();
          } catch (e) {
            // Response might be empty or not JSON
            console.log('Could not parse JSON response:', e);
          }
        }

        if (response.ok || response.status === 303) {
          // Success
          store.update((f) => ({
            ...f,
            processing: false,
            wasSuccessful: true,
            recentlySuccessful: true,
            errors: {},
          }));

          // Clear recentlySuccessful after 2 seconds
          setTimeout(() => {
            store.update((f) => ({ ...f, recentlySuccessful: false }));
          }, 2000);

          if (options.onSuccess) {
            options.onSuccess(responseData);
          }
        } else if (response.status === 422) {
          // Validation errors from Rails
          const errors = responseData.props?.errors || responseData.errors || {};
          store.update((f) => ({
            ...f,
            processing: false,
            errors: errors,
          }));

          if (options.onError) {
            options.onError(errors);
          }
        } else {
          // Other errors
          store.update((f) => ({
            ...f,
            processing: false,
            errors: { general: [`Server error: ${response.status}`] },
          }));

          if (options.onError) {
            options.onError({ general: [`Server error: ${response.status}`] });
          }
        }

        return response;
      } catch (error) {
        store.update((f) => ({ ...f, processing: false }));

        if (options.onError) {
          options.onError(error);
        }

        throw error;
      } finally {
        if (options.onFinish) {
          options.onFinish();
        }
      }
    },

    reset: (...fields) => {
      if (fields.length === 0) {
        store.set({
          ...initialData,
          errors: {},
          processing: false,
          progress: null,
          wasSuccessful: false,
          recentlySuccessful: false,
        });
      } else {
        store.update((f) => {
          const updated = { ...f };
          fields.forEach((field) => {
            if (field in initialData) {
              updated[field] = initialData[field];
            }
          });
          return updated;
        });
      }
    },

    clearErrors: (...fields) => {
      if (fields.length === 0) {
        store.update((f) => ({ ...f, errors: {} }));
      } else {
        store.update((f) => {
          const newErrors = { ...f.errors };
          fields.forEach((field) => delete newErrors[field]);
          return { ...f, errors: newErrors };
        });
      }
    },

    setError: (field, value) => {
      store.update((f) => ({
        ...f,
        errors: {
          ...f.errors,
          [field]: Array.isArray(value) ? value : [value],
        },
      }));
    },

    transform: (callback) => {
      // This would modify the data before sending
      // For simplicity, not implementing the full transform logic
      return form;
    },
  };

  return form;
};

// Mock page store
export const page = writable({
  props: {
    user: null,
    errors: {},
    flash: {},
  },
  component: 'TestComponent',
  url: '/',
  version: '1',
});

// Mock router that makes real HTTP requests
export const router = {
  visit: (url, options = {}) => {
    window.location.href = url;
  },

  post: async (url, data = {}, options = {}) => {
    return router.request('POST', url, data, options);
  },

  put: async (url, data = {}, options = {}) => {
    return router.request('PUT', url, data, options);
  },

  patch: async (url, data = {}, options = {}) => {
    return router.request('PATCH', url, data, options);
  },

  delete: async (url, data = {}, options = {}) => {
    return router.request('DELETE', url, data, options);
  },

  get: async (url, data = {}, options = {}) => {
    return router.request('GET', url, data, options);
  },

  reload: () => {
    window.location.reload();
  },

  request: async (method, url, data = {}, options = {}) => {
    try {
      const response = await fetch(url, {
        method: method,
        headers: {
          'Content-Type': 'application/json',
          'X-Inertia': 'true',
          'X-Requested-With': 'XMLHttpRequest',
          Accept: 'application/json',
        },
        credentials: 'include',
        body: method !== 'GET' ? JSON.stringify(data) : undefined,
      });

      let responseData = {};

      if (response.headers.get('content-type')?.includes('application/json')) {
        try {
          responseData = await response.json();
        } catch (e) {
          console.log('Could not parse JSON response:', e);
        }
      }

      if (response.ok || response.status === 302 || response.status === 303) {
        if (options.onSuccess) {
          options.onSuccess(responseData);
        }
      } else if (response.status === 422) {
        const errors = responseData.props?.errors || responseData.errors || {};
        if (options.onError) {
          options.onError(errors);
        }
      } else {
        if (options.onError) {
          options.onError({ general: [`Server error: ${response.status}`] });
        }
      }

      if (options.onFinish) {
        options.onFinish();
      }

      return response;
    } catch (error) {
      if (options.onError) {
        options.onError(error);
      }
      if (options.onFinish) {
        options.onFinish();
      }
      throw error;
    }
  },
};

export default {
  Link,
  useForm,
  page,
  router,
};
