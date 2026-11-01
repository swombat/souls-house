// One look for everything only site admins can see (Daniel, 2026-10-26, JOyyke):
// a single control or line is red text; a whole section sits in a light red box
// (AdminOnlySection). Use these, not ad-hoc reds, so "red" keeps meaning "admins only".
export const ADMIN_ONLY_TEXT = 'text-red-600 dark:text-red-400';
export const ADMIN_ONLY_FOCUS = 'focus:text-red-600 dark:focus:text-red-400';
export const ADMIN_ONLY_BOX =
  'rounded-lg border border-red-200 bg-red-50/70 p-4 dark:border-red-900/60 dark:bg-red-950/30';
