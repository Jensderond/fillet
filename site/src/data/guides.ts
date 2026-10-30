import { getCollection, type CollectionEntry } from 'astro:content';
import { GROUPS } from './groups';

export type Guide = CollectionEntry<'guides'>;

export const guideHref = (slug: string) => `/guides/${slug}/`;
export const glyphOf = (g: Guide) => g.data.glyph ?? g.id;

/** Every guide, in hub order (group, then order). */
export async function allGuides({ hidden = false } = {}): Promise<Guide[]> {
  const list = await getCollection('guides', (g: Guide) => hidden || !g.data.hidden);
  const rank = (g: Guide) => GROUPS.findIndex((x) => x.name === g.data.group);
  return list.sort((a, b) => rank(a) - rank(b) || a.data.order - b.data.order);
}

export async function guidesByGroup() {
  const list = await allGuides();
  return GROUPS.map((group) => ({ ...group, guides: list.filter((g) => g.data.group === group.name) }));
}
