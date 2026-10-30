import { reloadProps } from '$lib/cable';

// Reload some props every `interval` ms while the page is visible, and once
// when it becomes visible again. For state that can change by the clock with
// no broadcast: a run that ages out of the working window ends silently.
// Returns a cleanup, for $effect.
export function visibleRefresh(props, interval = 60_000) {
  if (typeof document === 'undefined') return () => {};

  const tick = () => {
    if (document.visibilityState === 'visible') reloadProps(props);
  };
  const timer = setInterval(tick, interval);
  document.addEventListener('visibilitychange', tick);
  return () => {
    clearInterval(timer);
    document.removeEventListener('visibilitychange', tick);
  };
}
