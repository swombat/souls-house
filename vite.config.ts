import { svelte } from '@sveltejs/vite-plugin-svelte';
import tailwindcss from '@tailwindcss/vite';
import { defineConfig } from 'vite';
import RubyPlugin from 'vite-plugin-ruby';
import path from 'path';

export default defineConfig({
  plugins: [svelte(), tailwindcss(), RubyPlugin()],
  assetsInclude: ['**/*.svg'],
  server: { strictPort: true },
  resolve: {
    alias: {
      $lib: path.resolve('./app/frontend/lib'),
    },
  },
});
