import type { APIRoute, GetStaticPaths } from 'astro';
import fs from 'node:fs';
import path from 'node:path';
import sharp from 'sharp';
import { allGuides, glyphOf } from '../../data/guides';
import { glyphFor } from '../../components/glyphs';

/**
 * Social preview images (Open Graph), 1200×630, made at build time: /og/index.png for the hub and
 * /og/<slug>.png for each guide. The guide's group, title and blurb sit on the dark graph paper,
 * beside the first screenshot the guide shows (or its glyph when it has none).
 */
const W = 1200, H = 630;
const SANS = "'Helvetica Neue', Helvetica, Arial, sans-serif";
const MONO = "Menlo, 'SF Mono', monospace";
const C = { bg: '#0e1320', ink: '#eef1f7', muted: '#949db0', accent: '#ff9a5c', tile: '#1a2850', panel: '#161e2f' };

interface Card { eyebrow: string; title: string; blurb: string; screen?: string; glyph?: string }

export const getStaticPaths = (async () => {
  const guides = await allGuides();
  const hub: Card = {
    eyebrow: 'User guide',
    title: 'Design 3D-printable parts on iPad and Mac',
    blurb: 'Sketch, add features, change anything later. Offline, parametric CAD.',
    screen: '/screens/getting-started/window-tour.png',
  };
  return [
    { params: { slug: 'index' }, props: hub },
    ...guides.map((g) => ({
      params: { slug: g.id },
      props: { eyebrow: g.data.group, title: g.data.title, blurb: g.data.blurb, screen: firstScreen(g.body ?? ''), glyph: glyphOf(g) },
    })),
  ];
}) satisfies GetStaticPaths;

/** The first still or video poster a guide shows. */
function firstScreen(body: string): string | undefined {
  return body.match(/(?:src|poster)="(\/screens\/[^"]+\.(?:png|jpe?g))"/)?.[1];
}

const esc = (s: string) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

/** Greedy word wrap by an average glyph width; the last kept line gets an ellipsis if text is left. */
function wrap(text: string, size: number, width: number, maxLines: number, em = 0.52): string[] {
  const perLine = Math.floor(width / (size * em));
  const lines: string[] = [];
  let line = '';
  const words = text.split(/\s+/);
  for (let i = 0; i < words.length; i++) {
    const next = line ? `${line} ${words[i]}` : words[i];
    if (next.length <= perLine || !line) { line = next; continue; }
    lines.push(line);
    line = words[i];
    if (lines.length === maxLines) { lines[maxLines - 1] = lines[maxLines - 1].replace(/[\s,.:;]*$/, '…'); return lines; }
  }
  if (line) lines.push(line);
  return lines;
}

function gridPattern(): string {
  return `
    <pattern id="minor" width="20" height="20" patternUnits="userSpaceOnUse">
      <path d="M20 0H0V20" fill="none" stroke="rgba(130,162,230,0.055)" stroke-width="1"/>
    </pattern>
    <pattern id="major" width="100" height="100" patternUnits="userSpaceOnUse">
      <rect width="100" height="100" fill="url(#minor)"/>
      <path d="M100 0H0V100" fill="none" stroke="rgba(130,162,230,0.13)" stroke-width="1"/>
    </pattern>`;
}

function glyphSvg(name: string | undefined, x: number, y: number, size: number): string {
  const g = glyphFor(name);
  if (!g) return '';
  const [vx, vy, vw, vh] = (g.viewBox ?? '0 0 32 32').split(/\s+/).map(Number);
  return `
    <rect x="${x}" y="${y}" width="${size}" height="${size}" rx="${size * 0.2}" fill="${C.tile}"/>
    <rect x="${x}" y="${y}" width="${size}" height="${size}" rx="${size * 0.2}" fill="url(#major)"/>
    <svg x="${x + size * 0.16}" y="${y + size * 0.16}" width="${size * 0.68}" height="${size * 0.68}" viewBox="${vx} ${vy} ${vw} ${vh}"
      fill="none" stroke="#e7edfa" stroke-width="${g.strokeWidth ?? 1.8}" stroke-linejoin="round" stroke-linecap="round">
      <style>.acc{fill:#ff7a30}.acc-s{stroke:#ff7a30}.sel{stroke:#5b9bff}.bg{fill:${C.tile};stroke:none}.ink{fill:#e7edfa}</style>
      ${g.svg}
    </svg>`;
}

/** The screenshot, fitted into the right-hand panel with rounded corners. */
async function screenshot(p: string, box: { w: number; h: number }) {
  const file = path.join(process.cwd(), 'src/assets', p);
  const img = sharp(fs.readFileSync(file)).resize({ width: box.w, height: box.h, fit: 'inside' });
  const { data, info } = await img.png().toBuffer({ resolveWithObject: true });
  const r = 14;
  const mask = Buffer.from(`<svg width="${info.width}" height="${info.height}"><rect width="${info.width}" height="${info.height}" rx="${r}" fill="#fff"/></svg>`);
  const rounded = await sharp(data).composite([{ input: mask, blend: 'dest-in' }]).png().toBuffer();
  return { input: rounded, width: info.width, height: info.height };
}

export const GET: APIRoute = async ({ props }) => {
  const card = props as Card;
  const PAD = 72;
  const shot = card.screen ? await screenshot(card.screen, { w: 500, h: 440 }) : undefined;
  const textWidth = shot || card.glyph ? 540 : W - 2 * PAD;

  const title = wrap(card.title, 56, textWidth, 3);
  const blurb = wrap(card.blurb, 26, textWidth, 3, 0.5);
  const titleTop = 252;
  const blurbTop = titleTop + title.length * 64 + 22;

  const right = shot
    ? { x: W - PAD - shot.width + 12, y: Math.round((H - shot.height) / 2) + 20 }
    : undefined;

  const svg = `
<svg width="${W}" height="${H}" viewBox="0 0 ${W} ${H}" xmlns="http://www.w3.org/2000/svg">
  <defs>${gridPattern()}
    <filter id="shadow" x="-10%" y="-10%" width="120%" height="130%">
      <feDropShadow dx="0" dy="18" stdDeviation="22" flood-color="#000" flood-opacity="0.55"/>
    </filter>
  </defs>
  <rect width="${W}" height="${H}" fill="${C.bg}"/>
  <rect width="${W}" height="${H}" fill="url(#major)"/>
  ${right && shot ? `<rect x="${right.x}" y="${right.y}" width="${shot.width}" height="${shot.height}" rx="14" fill="${C.panel}" filter="url(#shadow)"/>` : ''}
  ${!shot && card.glyph ? glyphSvg(card.glyph, W - PAD - 300, (H - 300) / 2 + 20, 300) : ''}
  <text x="${PAD + 72}" y="${PAD + 38}" font-family="${SANS}" font-size="30" font-weight="700" fill="${C.ink}">Fillet <tspan font-weight="400" fill="${C.muted}">Guide</tspan></text>
  <text x="${PAD}" y="${titleTop - 66}" font-family="${MONO}" font-size="19" font-weight="700" letter-spacing="2.4" fill="${C.accent}">${esc(card.eyebrow.toUpperCase())}</text>
  ${title.map((l, i) => `<text x="${PAD}" y="${titleTop + i * 64}" font-family="${SANS}" font-size="56" font-weight="700" letter-spacing="-1.2" fill="${C.ink}">${esc(l)}</text>`).join('\n  ')}
  ${blurb.map((l, i) => `<text x="${PAD}" y="${blurbTop + i * 36}" font-family="${SANS}" font-size="26" fill="${C.muted}">${esc(l)}</text>`).join('\n  ')}
</svg>`;

  const icon = await sharp(path.join(process.cwd(), 'public/brand/icon-128.png')).resize(56, 56).png().toBuffer();
  const layers: sharp.OverlayOptions[] = [{ input: icon, left: PAD, top: PAD }];
  if (shot && right) layers.push({ input: shot.input, left: right.x, top: right.y });
  const png = await sharp(Buffer.from(svg)).composite(layers).png({ compressionLevel: 9 }).toBuffer();
  return new Response(new Uint8Array(png), { headers: { 'Content-Type': 'image/png' } });
};
