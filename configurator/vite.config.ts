/// <reference types="vitest/config" />
import { defineConfig } from 'vite';
import tailwindcss from '@tailwindcss/vite';

// Relative base so the built site works whether it's deployed at the Pages
// repo subpath (roonlabs.github.io/roon-docker/) or a custom domain root.
export default defineConfig({
  base: './',
  plugins: [tailwindcss()],
  build: {
    outDir: 'dist',
    sourcemap: true,
    target: 'es2022',
  },
  test: {
    // Keep Vitest scoped to the src/ unit tests. The Playwright specs under
    // e2e/ are not meant to run in the Vitest runner.
    include: ['src/**/*.test.ts'],
  },
});
