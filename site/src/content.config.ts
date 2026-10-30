import { defineCollection } from 'astro:content';
import { glob } from 'astro/loaders';
import { z } from 'astro/zod';
import { GROUPS } from './data/groups';

const guides = defineCollection({
  loader: glob({ pattern: '*.{md,mdx}', base: './src/content/guides' }),
  schema: z.object({
    title: z.string(),
    /** Short name for the footer and tight lists. */
    short: z.string().optional(),
    /** Hub section; one of the names in src/data/groups.ts. */
    group: z.enum(GROUPS.map((g) => g.name) as [string, ...string[]]),
    /** Position inside its group on the hub. */
    order: z.number(),
    /** Glyph name from src/components/glyphs.ts. Defaults to the slug. */
    glyph: z.string().optional(),
    /** One line for hub cards, related cards and search results. */
    blurb: z.string(),
    /** One or two sentences under the H1. */
    lede: z.string().optional(),
    /** The writer's brief: what the guide must cover. Shown on stubs only. */
    summary: z.string().optional(),
    /** Slugs for the closing Related guides grid (up to 4). */
    related: z.array(z.string()).optional(),
    /** Hide the "In this guide" box (e.g. on reference pages). */
    toc: z.boolean().optional(),
    /** Kept off the hub, footer and search (e.g. the component styleguide). */
    hidden: z.boolean().optional(),
  }),
});

export const collections = { guides };
