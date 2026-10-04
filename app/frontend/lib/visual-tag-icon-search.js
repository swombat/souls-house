// Search metadata belongs to the chooser, not every sidebar icon render.
import keywords from '../assets/visual-tag-icon-keywords.json';
import categories from '../assets/visual-tag-icon-categories.json';
import { iconLabel, visualTagIconNames } from './visual-tags';

export const visualTagIconKeywords = Object.freeze(keywords);
export const visualTagCategories = [
  'communications',
  'nature',
  'people',
  'health & wellness',
  'objects',
  'media',
  'maps & travel',
  'games',
  'weather',
  'commerce',
  'finances',
  'office',
  'technology & development',
  'design',
  'system',
  'editor',
  'arrows',
  'brands',
];
const suggested = [
  'ChatCircle',
  'Wrench',
  'MagnifyingGlass',
  'Sparkle',
  'Heart',
  'Palette',
  'BookOpen',
  'Compass',
  'Lifebuoy',
  'Lightbulb',
  'Flask',
  'Code',
  'MusicNote',
  'Camera',
  'Leaf',
  'Sun',
  'Moon',
  'Star',
  'Globe',
  'Calendar',
  'CheckCircle',
  'Flag',
  'Handshake',
  'House',
  'Briefcase',
  'GraduationCap',
  'Bookmark',
  'Lightning',
  'Coffee',
  'Plant',
  'Atom',
  'Coins',
];

// Each icon appears once in the unfiltered browse, but in every relevant category filter.
export function visualTagBrowseGroups(options, category = '') {
  if (category) return [{ label: category, icons: options.filter((name) => categories[name]?.includes(category)) }];
  const remaining = new Set(options);
  const groups = [{ label: 'Suggested', icons: suggested.filter((name) => remaining.delete(name)) }];
  for (const label of visualTagCategories) {
    const icons = options.filter((name) => remaining.has(name) && categories[name]?.includes(label));
    icons.forEach((name) => remaining.delete(name));
    if (icons.length) groups.push({ label, icons });
  }
  if (remaining.size) groups.push({ label: 'More icons', icons: [...remaining] });
  return groups;
}
const searchText = new Map(
  visualTagIconNames.map((name) => [name, `${name} ${iconLabel(name)} ${keywords[name].join(' ')}`.toLowerCase()])
);

// Match every query word against labels and upstream categories/keyword tags.
export function visualTagIconMatches(icon, query) {
  const text = searchText.get(icon);
  if (text === undefined) return false;
  return query
    .trim()
    .toLowerCase()
    .split(/\s+/)
    .every((term) => text.includes(term));
}
