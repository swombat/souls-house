import {
  ChatCircle,
  Wrench,
  MagnifyingGlass,
  Sparkle,
  Heart,
  Palette,
  BookOpen,
  Compass,
  Lifebuoy,
  Lightbulb,
  Flask,
  Code,
  MusicNote,
  Camera,
  Leaf,
  Sun,
  Moon,
  Star,
  Globe,
  Calendar,
  CheckCircle,
  Flag,
  Handshake,
  House,
  Briefcase,
  GraduationCap,
  Bookmark,
  Lightning,
} from 'phosphor-svelte';

export const visualTagIcons = {
  ChatCircle,
  Wrench,
  MagnifyingGlass,
  Sparkle,
  Heart,
  Palette,
  BookOpen,
  Compass,
  Lifebuoy,
  Lightbulb,
  Flask,
  Code,
  MusicNote,
  Camera,
  Leaf,
  Sun,
  Moon,
  Star,
  Globe,
  Calendar,
  CheckCircle,
  Flag,
  Handshake,
  House,
  Briefcase,
  GraduationCap,
  Bookmark,
  Lightning,
};

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

export function visualTagIcon(icon) {
  return visualTagIcons[icon] || ChatCircle;
}

export function visualTagColour(colour) {
  return visualTagColours[colour] || visualTagColours.slate;
}

export function iconLabel(icon) {
  return icon.replace(/([a-z])([A-Z])/g, '$1 $2');
}
