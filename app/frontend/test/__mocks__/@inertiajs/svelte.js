import { writable, readable } from 'svelte/store';
import { vi } from 'vitest';
import Link from '../Link.svelte';

// Export the mocked Link component
export { Link };

// Mock useForm hook
export const useForm = vi.fn((initialData) => {
  // Create the main form data store
  const formData = {
    email_address: '',
    password: '',
    password_confirmation: '',
    ...initialData,
  };

  // Create errors as a nested object in the form with empty arrays
  formData.errors = {
    email_address: [],
    password: [],
    password_confirmation: [],
  };

  // Real Inertia returns a writable store. Its methods and boolean state live
  // on the value ($form), not the store itself (form).
  return writable({
    ...formData,
    processing: false,
    recentlySuccessful: false,
    post: vi.fn(() => Promise.resolve()),
    put: vi.fn(() => Promise.resolve()),
    patch: vi.fn(() => Promise.resolve()),
    delete: vi.fn(() => Promise.resolve()),
    get: vi.fn(() => Promise.resolve()),
    reset: vi.fn(),
    clearErrors: vi.fn(),
    transform: vi.fn(),
  });
});

// Mock page store
export const page = readable({
  props: {
    user: null,
    errors: {},
    flash: {},
  },
  component: 'TestComponent',
  url: '/',
  version: null,
});

// Mock router. Global listeners registered with router.on are kept in routerListeners so a
// test can fire them (vi.clearAllMocks would otherwise erase import-time registrations).
export const routerListeners = {};
export const router = {
  on: vi.fn((type, callback) => {
    (routerListeners[type] ||= []).push(callback);
    return () => {};
  }),
  visit: vi.fn(),
  get: vi.fn(),
  post: vi.fn(),
  put: vi.fn(),
  patch: vi.fn(),
  delete: vi.fn(),
  reload: vi.fn(),
};

// Mock Deferred component (stub)
export const Deferred = {
  name: 'Deferred',
  render: () => ({
    html: '<div></div>',
    css: { code: '', map: null },
    head: '',
  }),
};

export default {
  Link,
  useForm,
  page,
  router,
  Deferred,
};
