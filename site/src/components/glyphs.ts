/**
 * Line glyphs for guides, drawn in the style of the app icon: ink outlines with an
 * orange accent (the app's "in progress" colour) and, for selection, the app's blue.
 *
 * Each glyph is SVG markup for a 32×32 viewBox unless `viewBox` says otherwise.
 * Classes: `acc` fills orange, `acc-s` strokes orange, `sel` strokes blue,
 * `bg` fills with the tile colour (to hide lines behind a shape), `ink` fills ink.
 */
export interface GlyphDef {
  viewBox?: string;
  strokeWidth?: number;
  svg: string;
}

const iso = {
  top: 'M6 10.5 L16 5 L26 10.5 L16 16 Z',
  left: 'M6 10.5 L16 16 L16 27 L6 21.5 Z',
  right: 'M16 16 L26 10.5 L26 21.5 L16 27 Z',
};

export const GLYPHS: Record<string, GlyphDef> = {
  'getting-started': {
    // The app icon in miniature: a box with one edge rounded over.
    viewBox: '112 100 800 860',
    strokeWidth: 52,
    svg: `
      <path class="bg" d="M152 404.6 L338 458 Q553.7 520 553.7 736.5 L553.7 923.4 L152 808 Z"/>
      <path class="bg" d="M152 404.6 L470 132.5 L656 186 L338 458 Z"/>
      <path class="bg" d="M553.7 923.4 L872 651.4 L872 464.5 L553.7 736.5 Z"/>
      <path class="acc" d="M338 458 L656 186 Q872 248 872 464.5 L553.7 736.5 Q553.7 520 338 458 Z"/>
      <path d="M152 404.6 L338 458 Q553.7 520 553.7 736.5 L553.7 923.4 L152 808 Z"/>
      <path d="M152 404.6 L470 132.5 L656 186"/>
      <path d="M656 186 Q872 248 872 464.5 L872 651.4 L553.7 923.4"/>
      <path d="M553.7 736.5 L872 464.5" stroke-width="22"/>
      <path d="M338 458 L656 186" stroke-width="22"/>`,
  },
  install: {
    // A download arrow dropping into a tray.
    svg: `
      <path d="M6 18.5 V26 H26 V18.5"/>
      <path class="acc-s" d="M16 5 V19 M10.5 13.5 L16 19 L21.5 13.5"/>`,
  },
  'files-and-icloud': {
    svg: `
      <path class="bg" d="M8 4 H19 L25 10 V28 H8 Z"/>
      <path class="acc" d="M19 4 V10 H25 Z" stroke-linejoin="round"/>
      <path d="M8 4 H19 L25 10 V28 H8 Z"/>
      <path d="M12 16 H21 M12 20 H21 M12 24 H17"/>`,
  },
  sketching: {
    svg: `
      <rect x="5" y="7" width="15" height="15" rx="0.5"/>
      <circle class="acc-s" cx="20" cy="20" r="7" stroke-width="2.2"/>
      <rect class="ink" x="3.4" y="5.4" width="3.2" height="3.2" stroke="none"/>
      <rect class="ink" x="18.4" y="5.4" width="3.2" height="3.2" stroke="none"/>
      <rect class="ink" x="3.4" y="20.4" width="3.2" height="3.2" stroke="none"/>
      <circle class="ink" cx="20" cy="20" r="1.4" stroke="none"/>`,
  },
  'extrude-revolve-press-pull': {
    svg: `
      <path class="bg" d="M6 15 L16 10 L26 15 L26 22 L16 27 L6 22 Z"/>
      <path d="M6 15 L16 10 L26 15 L16 20 Z"/>
      <path d="M6 15 V22 L16 27 L26 22 V15 M16 20 V27"/>
      <path class="acc-s" d="M16 15 V2.8 M12.4 6.4 L16 2.8 L19.6 6.4" stroke-width="2.4"/>`,
  },
  'fillet-chamfer-shell': {
    svg: `
      <path class="bg" d="M5 27 V6 H15 Q27 6 27 18 V27 Z"/>
      <path d="M5 27 V6 H15 M27 18 V27 H5"/>
      <path class="acc-s" d="M15 6 Q27 6 27 18" stroke-width="3"/>
      <path d="M15 6 V3 M27 18 H30" stroke-width="1.2"/>`,
  },
  holes: {
    svg: `
      <path class="bg" d="M3 16 L16 9.5 L29 16 V20 L16 26.5 L3 20 Z"/>
      <path d="M3 16 L16 9.5 L29 16 L16 22.5 Z"/>
      <path d="M3 16 V20 L16 26.5 L29 20 V16 M16 22.5 V26.5"/>
      <ellipse class="acc" cx="16" cy="16" rx="6.4" ry="3.2"/>
      <ellipse class="bg" cx="16" cy="16.6" rx="3.4" ry="1.7"/>`,
  },
  bodies: {
    svg: `
      <path class="bg" d="M3 15 L9.5 11.5 L16 15 V23 L9.5 26.5 L3 23 Z"/>
      <path d="M3 15 L9.5 11.5 L16 15 L9.5 18.5 Z M3 15 V23 L9.5 26.5 L16 23 V15 M9.5 18.5 V26.5"/>
      <path class="bg" d="M17 8 V22 A5 2.2 0 0 0 27 22 V8 Z"/>
      <path d="M17 8 V22 A5 2.2 0 0 0 27 22 V8"/>
      <ellipse class="acc" cx="22" cy="8" rx="5" ry="2.2"/>`,
  },
  patterns: {
    svg: `
      <circle class="ink" cx="7.5" cy="10.5" r="3.4" stroke="none"/>
      <circle class="acc-s" cx="16" cy="10.5" r="3.2" stroke-width="2"/>
      <circle class="acc-s" cx="24.5" cy="10.5" r="3.2" stroke-width="2"/>
      <circle class="acc-s" cx="7.5" cy="21.5" r="3.2" stroke-width="2"/>
      <circle class="acc-s" cx="16" cy="21.5" r="3.2" stroke-width="2"/>
      <circle class="acc-s" cx="24.5" cy="21.5" r="3.2" stroke-width="2"/>`,
  },
  selecting: {
    svg: `
      <path class="bg" d="${iso.top} ${iso.left} ${iso.right}"/>
      <path d="M6 10.5 L16 5 L26 10.5 L16 16 Z M6 10.5 V21.5 L16 27 L26 21.5 V10.5"/>
      <path class="sel" d="M16 16 V27" stroke-width="3.2"/>
      <circle class="sel" cx="16" cy="21.5" r="4.6" stroke-width="1.4" opacity=".55"/>`,
  },
  parameters: {
    svg: `
      <text x="4" y="22.5" font-family="ui-serif, Georgia, serif" font-style="italic" font-weight="700" font-size="19" class="ink" stroke="none">f</text>
      <text x="14" y="22.5" font-family="ui-monospace, Menlo, monospace" font-weight="700" font-size="13" class="acc" stroke="none">=x</text>`,
  },
  timeline: {
    svg: `
      <path d="M3 21 H29"/>
      <path d="M5 21 V24 M10 21 V23 M15 21 V24 M20 21 V23 M25 21 V24" stroke-width="1.2"/>
      <circle class="ink" cx="7" cy="14" r="2.6" stroke="none"/>
      <circle class="ink" cx="13.5" cy="14" r="2.6" stroke="none"/>
      <circle cx="20" cy="14" r="2.4"/>
      <path class="acc-s" d="M25 8 V27" stroke-width="2.4"/>
      <path class="acc" d="M22 5 H28 L25 9 Z"/>`,
  },
  measure: {
    svg: `
      <path d="M4 26 H28" stroke-width="2.6"/>
      <path d="M7 23 V7 M25 23 V7" stroke-width="1.2"/>
      <path class="acc-s" d="M7 13 H25 M10.5 10 L7 13 L10.5 16 M21.5 10 L25 13 L21.5 16" stroke-width="2"/>`,
  },
  'section-view': {
    svg: `
      <defs><clipPath id="glyph-section-cap"><path d="${iso.right}"/></clipPath></defs>
      <path class="bg" d="${iso.top} ${iso.left}"/>
      <path class="acc" d="${iso.right}"/>
      <g clip-path="url(#glyph-section-cap)" stroke="#fff" stroke-width="1.1" opacity=".75">
        <path d="M8 28 L32 4 M12 32 L36 8 M4 24 L28 0 M16 36 L40 12 M0 20 L24 -4"/>
      </g>
      <path d="M6 10.5 L16 5 L26 10.5 L16 16 Z M6 10.5 V21.5 L16 27 L26 21.5 V10.5 M16 16 V27"/>`,
  },
  // The Section button on the app's tool strip (for inline <Ui> use): a square with a cut across it.
  'tool-section': {
    svg: `
      <rect x="6" y="6" width="20" height="20" rx="3.5"/>
      <path d="M9.5 22.5 L22.5 9.5"/>`,
  },
  'print-check-and-export': {
    svg: `
      <path class="bg" d="M2 21 L16 14 L30 21 L16 28 Z"/>
      <path d="M2 21 L16 14 L30 21 L16 28 Z"/>
      <path d="M9 17.5 L23 24.5 M9 24.5 L23 17.5" stroke-width="0.9" opacity=".55"/>
      <path class="bg" d="M11 12 L16 9.5 L21 12 V19 L16 21.5 L11 19 Z"/>
      <path class="acc" d="M11 12 L16 9.5 L21 12 L16 14.5 Z"/>
      <path d="M11 12 L16 9.5 L21 12 L16 14.5 Z M11 12 V19 L16 21.5 L21 19 V12 M16 14.5 V21.5"/>`,
  },
  'agents-mcp': {
    svg: `
      <path class="acc" d="M14 4 C15 11 18 14.5 25 16 C18 17.5 15 21 14 28 C13 21 10 17.5 3 16 C10 14.5 13 11 14 4 Z" stroke-width="1.4"/>
      <path class="ink" d="M25 3 C25.4 5.6 26.4 6.6 29 7 C26.4 7.4 25.4 8.4 25 11 C24.6 8.4 23.6 7.4 21 7 C23.6 6.6 24.6 5.6 25 3 Z" stroke="none"/>`,
  },
  'keyboard-shortcuts': {
    svg: `
      <rect class="bg" x="4" y="4" width="24" height="24" rx="5"/>
      <rect x="4" y="4" width="24" height="24" rx="5"/>
      <rect x="7" y="6.5" width="18" height="16.5" rx="3" stroke-width="1.2"/>
      <text x="16" y="19.6" text-anchor="middle" font-family="-apple-system, system-ui, sans-serif" font-weight="600" font-size="12" class="acc" stroke="none">⌘</text>`,
  },
};

export function glyphFor(name?: string): GlyphDef | undefined {
  return name ? GLYPHS[name] : undefined;
}
