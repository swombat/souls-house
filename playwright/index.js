// Import styles
import './styles.css';

// This file is required for Playwright component testing
// It sets up the environment before mounting components

// Mock window.global if needed for Rails UJS or other libraries
if (typeof window !== 'undefined') {
  // Add any global setup here
  window.global = window;
  
  // Mock Inertia global if components expect it
  window.Inertia = {
    visit: () => {},
    post: () => {},
    put: () => {},
    patch: () => {},
    delete: () => {},
    reload: () => {},
  };
}
