// Search metadata belongs to the chooser, not every sidebar icon render.
import keywords from '../assets/visual-tag-icon-keywords.json';
import { iconLabel, visualTagIconNames } from './visual-tags';

export const visualTagIconKeywords = Object.freeze(keywords);
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
