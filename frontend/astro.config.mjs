// @ts-check
import { defineConfig } from 'astro/config';
import alpinejs from '@astrojs/alpinejs';
import tailwind from '@tailwindcss/vite';

// Static build that the Zig server serves out of repo-root `dist/`.
// `build.format: 'file'` emits dist/<page>.html (not <page>/index.html) so the
// server's explicit `.html` routes map 1:1.
export default defineConfig({
  output: 'static',
  outDir: '../dist',
  build: { format: 'file' },
  integrations: [alpinejs({ entrypoint: '/src/scripts/alpine-stores' })],
  vite: {
    plugins: [tailwind()],
  },
});
