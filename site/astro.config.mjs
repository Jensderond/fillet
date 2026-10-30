// @ts-check
import { defineConfig } from 'astro/config';
import mdx from '@astrojs/mdx';
import fs from 'node:fs';

// The docs review board (/progress) lives in review/, which is gitignored and only loaded by
// `astro dev`: it is never part of a build.
const reviewEntry = new URL('./review/integration.mjs', import.meta.url);
const review = fs.existsSync(reviewEntry) ? [(await import(reviewEntry.href)).default()] : [];

export default defineConfig({
  site: 'https://fillet.jsdr.dev',
  trailingSlash: 'ignore',
  integrations: [mdx(), ...review],
  server: { port: 4321, host: '127.0.0.1' },
  devToolbar: { enabled: false },
});
