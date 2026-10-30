import type { APIRoute } from 'astro';
import { allGuides, glyphOf } from '../data/guides';

// Strip MDX down to readable text for matching.
const plain = (s: string) => s
  .replace(/^import .*$/gm, '')
  .replace(/<[^>]*?(?:caption|alt|q|text|title|combo)="([^"]*)"[^>]*>/g, ' $1 ')
  .replace(/<\/?[A-Za-z][^>]*>/g, ' ')
  .replace(/!\[[^\]]*\]\([^)]*\)/g, ' ')
  .replace(/\[([^\]]*)\]\([^)]*\)/g, '$1')
  .replace(/[#*_`>|{}]/g, ' ')
  .replace(/\s+/g, ' ')
  .trim();
const slugify = (s: string) => s.toLowerCase().trim().replace(/[^\p{L}\p{N}\s-]/gu, '').replace(/\s+/g, '-');

export const GET: APIRoute = async () => {
  const guides = await allGuides();
  const out = guides.map((g) => {
    const body = g.body ?? '';
    const headings = [...body.matchAll(/^#{2,3}\s+(.+)$/gm)].map((m) => ({ text: m[1].trim(), slug: slugify(m[1]) }));
    return {
      slug: g.id,
      title: g.data.title,
      blurb: g.data.blurb,
      group: g.data.group,
      glyph: glyphOf(g),
      headings,
      text: plain([g.data.lede ?? '', body.trim() ? body : g.data.summary ?? ''].join(' ')),
    };
  });
  return new Response(JSON.stringify(out), { headers: { 'Content-Type': 'application/json' } });
};
