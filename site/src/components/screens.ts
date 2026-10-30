// Guide media live in src/assets/screens/<slug>/ and are referenced from MDX as
// "/screens/<slug>/<file>". Images go through Astro's image pipeline (sharp, at build time):
// every screenshot ships as AVIF and WebP at several widths, with the original format as the
// fallback. Clips (mp4) are copied as they are, with a hashed URL.
import type { ImageMetadata } from 'astro';
import { getImage } from 'astro:assets';

const images = import.meta.glob<ImageMetadata>('../assets/screens/**/*.{png,jpg,jpeg}', { eager: true, import: 'default' });
const clips = import.meta.glob<string>('../assets/screens/**/*.mp4', { eager: true, query: '?url', import: 'default' });

/** Widths the srcset offers, capped at each image's own width (which is always included). */
const WIDTHS = [480, 800, 1200, 1600, 2400];
/** The fallback <img> for browsers without AVIF or WebP: no wider than this. */
const FALLBACK_WIDTH = 1600;

function lookup<T>(table: Record<string, T>, path: string): T {
  const found = table[`../assets${path}`];
  if (!found) throw new Error(`No media at src/assets${path} (referenced as "${path}")`);
  return found;
}

export const screen = (path: string) => lookup(images, path);
export const clip = (path: string) => lookup(clips, path);

export interface Sources { avif: string; webp: string; src: string; width: number; height: number }

/** srcsets in AVIF and WebP, plus a fallback src, for one screenshot. */
export async function sources(path: string): Promise<Sources> {
  const img = screen(path);
  const widths = [...WIDTHS.filter((w) => w < img.width), img.width];
  const [avif, webp, fallback] = await Promise.all([
    getImage({ src: img, widths, format: 'avif' }),
    getImage({ src: img, widths, format: 'webp' }),
    getImage({ src: img, width: Math.min(img.width, FALLBACK_WIDTH), format: img.format === 'png' ? 'png' : 'jpg' }),
  ]);
  return { avif: avif.srcSet.attribute, webp: webp.srcSet.attribute, src: fallback.src, width: img.width, height: img.height };
}

/** A video poster: one WebP frame, no wider than the fallback width. */
export async function poster(path: string): Promise<string> {
  const img = screen(path);
  return (await getImage({ src: img, width: Math.min(img.width, FALLBACK_WIDTH), format: 'webp' })).src;
}

/** `sizes` for a figure: the wide figure column (900px), or `maxWidth` when it is capped. */
export const sizesFor = (maxWidth?: number) =>
  `(max-width: ${(maxWidth ?? 900) + 48}px) 100vw, ${maxWidth ?? 900}px`;
