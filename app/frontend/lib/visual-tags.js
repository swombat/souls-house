import iconNames from '../../../config/visual_tag_icons.json';

export const visualTagIconNames = Object.freeze(iconNames);
const validIconNames = new Set(visualTagIconNames);

export const visualTagColours = {
  slate: 'text-slate-600 dark:text-slate-300',
  blue: 'text-blue-600 dark:text-blue-400',
  teal: 'text-teal-700 dark:text-teal-400',
  violet: 'text-violet-600 dark:text-violet-400',
  rose: 'text-rose-600 dark:text-rose-400',
  amber: 'text-amber-700 dark:text-amber-400',
  indigo: 'text-indigo-600 dark:text-indigo-400',
  green: 'text-green-700 dark:text-green-400',
  orange: 'text-orange-700 dark:text-orange-400',
  red: 'text-red-600 dark:text-red-400',
  yellow: 'text-yellow-700 dark:text-yellow-400',
  cyan: 'text-cyan-700 dark:text-cyan-400',
  pink: 'text-pink-600 dark:text-pink-400',
};

export function visualTagIconName(icon) {
  return validIconNames.has(icon) ? icon : 'ChatCircle';
}

export function visualTagColour(colour) {
  return Object.hasOwn(visualTagColours, colour) ? visualTagColours[colour] : visualTagColours.slate;
}

export function iconLabel(icon) {
  return icon.replace(/([A-Z]+)([A-Z][a-z])/g, '$1 $2').replace(/([a-z0-9])([A-Z])/g, '$1 $2');
}
