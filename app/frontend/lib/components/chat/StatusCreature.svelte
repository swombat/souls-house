<script>
  // One resident's status creature (eKmBwJ): the same creature through a run,
  // rising while it arrives, alive while it is here, resting once it settles.
  // Decoration only: the phrase beside it carries the meaning, so this is
  // hidden from assistive technology, and reduced motion stills it.
  import { statusCreatureMarkup } from '$lib/status-creatures';

  let { family, stage, colour = null } = $props();

  const markup = $derived(statusCreatureMarkup(family, stage));
  const colourClass = $derived(colour ? `text-${colour}-600 dark:text-${colour}-300` : 'text-muted-foreground');
  const style = $derived(
    colour
      ? `--creature-ground: var(--color-${colour}-100); --creature-ground-dark: var(--color-${colour}-900)`
      : null
  );
</script>

{#if markup}
  <span
    class="status-creature inline-block align-[-3px] {colourClass}"
    aria-hidden="true"
    data-testid="status-creature"
    data-family={family}
    data-stage={stage}
    {style}>
    <svg
      viewBox="0 0 24 24"
      width="18"
      height="18"
      fill="none"
      stroke="currentColor"
      stroke-width="1.8"
      stroke-linecap="round"
      stroke-linejoin="round"
      focusable="false">
      {@html markup}
    </svg>
  </span>
{/if}

<style>
  .status-creature {
    --creature-eye: var(--creature-ground, var(--background));
  }
  :global(.dark) .status-creature {
    --creature-eye: var(--creature-ground-dark, var(--background));
  }
  .status-creature :global(svg *) {
    transform-box: fill-box;
    transform-origin: center;
  }
  .status-creature :global(.fill) {
    fill: currentColor;
  }
  .status-creature :global(.ns) {
    stroke: none;
  }
  .status-creature :global(.eye) {
    fill: var(--creature-eye);
    stroke: none;
  }
  .status-creature :global(.lid) {
    stroke: var(--creature-eye);
    stroke-width: 1;
  }
  .status-creature :global(.a-rise) {animation:sc-rise 2.6s ease-out infinite}
  @keyframes -global-sc-rise {0%{transform:translateY(7px);opacity:0}45%,100%{transform:none;opacity:1}}
  .status-creature :global(.a-breathe) {animation:sc-breathe 3.2s ease-in-out infinite}
  @keyframes -global-sc-breathe {0%,100%{transform:scale(.85)}50%{transform:scale(1.15)}}
  .status-creature :global(.a-drop) {animation:sc-drop 2.2s ease-in infinite}
  @keyframes -global-sc-drop {0%{transform:translateY(0);opacity:0}15%{opacity:1}70%{transform:translateY(14px);opacity:1}100%{transform:translateY(14px) scale(2.4,.3);opacity:0}}
  .status-creature :global(.a-ring) {animation:sc-ring 3.6s ease-out infinite}
  .status-creature :global(.a-ring.d2) {animation-delay:1.8s}
  @keyframes -global-sc-ring {0%{transform:scale(.25);opacity:.9}100%{transform:scale(1);opacity:0}}
  .status-creature :global(.a-catch) {transform-origin:50% 100%;animation:sc-catch 2.4s ease-out infinite}
  @keyframes -global-sc-catch {0%{transform:scale(.15);opacity:.2}20%{opacity:1}30%{opacity:.4}50%,100%{transform:none;opacity:1}}
  .status-creature :global(.a-sway) {transform-origin:50% 100%;animation:sc-sway 3s ease-in-out infinite}
  @keyframes -global-sc-sway {0%,100%{transform:rotate(-5deg) scaleY(1)}50%{transform:rotate(5deg) scaleY(1.06)}}
  .status-creature :global(.a-blink) {animation:sc-blink 4s infinite}
  @keyframes -global-sc-blink {0%,44%,52%,100%{transform:scaleY(1)}48%{transform:scaleY(.1)}}
  .status-creature :global(.a-bob) {animation:sc-bob 3s ease-in-out infinite}
  @keyframes -global-sc-bob {0%,100%{transform:translateY(1px)}50%{transform:translateY(-1.5px)}}
  .status-creature :global(.a-land) {animation:sc-land 2.8s ease-out infinite}
  @keyframes -global-sc-land {0%{transform:translate(-9px,-9px);opacity:0}15%{opacity:1}50%{transform:translate(0,1px)}58%,100%{transform:none;opacity:1}}
  .status-creature :global(.a-hop) {animation:sc-hop 2.4s ease-in-out infinite}
  @keyframes -global-sc-hop {0%,30%,60%,100%{transform:none}15%,45%{transform:translateY(-1.6px)}}
  .status-creature :global(.a-note) {animation:sc-note 2.4s ease-out infinite}
  @keyframes -global-sc-note {0%,25%{transform:translate(-2px,3px);opacity:0}45%{opacity:1}100%{transform:translate(1px,-2px);opacity:0}}
  .status-creature :global(.a-tail) {transform-origin:0% 100%;animation:sc-tail 2.6s ease-in-out infinite}
  @keyframes -global-sc-tail {0%,100%{transform:rotate(-8deg)}50%{transform:rotate(12deg)}}
  .status-creature :global(.a-earup) {transform-origin:100% 100%;animation:sc-earup 2.8s ease-out infinite}
  @keyframes -global-sc-earup {0%,15%{transform:rotate(-80deg)}55%,100%{transform:none}}
  .status-creature :global(.a-ear) {transform-origin:100% 100%;animation:sc-ear 3s ease-in-out infinite}
  @keyframes -global-sc-ear {0%,100%{transform:rotate(-6deg)}50%{transform:rotate(22deg)}}
  .status-creature :global(.a-sprout) {transform-origin:0% 100%;animation:sc-sprout 2.8s ease-out infinite}
  @keyframes -global-sc-sprout {0%,15%{transform:scale(.1);opacity:0}60%,100%{transform:none;opacity:1}}
  .status-creature :global(.a-nod) {transform-origin:20% 100%;animation:sc-nod 3s ease-in-out infinite}
  @keyframes -global-sc-nod {0%,100%{transform:rotate(-8deg)}50%{transform:rotate(12deg)}}
  .status-creature :global(.a-fall) {animation:sc-fall 2.4s ease-in infinite}
  @keyframes -global-sc-fall {0%{transform:translateY(-6px);opacity:0}15%{opacity:1}70%{transform:translateY(7px) scale(1,1)}80%{transform:translateY(8.5px) scale(1.2,.8)}90%,100%{transform:translateY(7px);opacity:1}}
  .status-creature :global(.a-puddle) {opacity:.5;animation:sc-puddle 3s ease-out infinite}
  @keyframes -global-sc-puddle {0%{transform:scaleX(.4);opacity:.8}100%{transform:scaleX(1.1);opacity:0}}
  .status-creature :global(.a-bell) {transform-origin:50% 100%;animation:sc-bell 2.8s ease-in-out infinite}
  @keyframes -global-sc-bell {0%,100%{transform:scale(1.04,.94)}50%{transform:scale(.82,1.08)}}
  .status-creature :global(.a-dropin) {animation:sc-dropin 2.8s ease-out infinite}
  @keyframes -global-sc-dropin {0%{transform:translateY(-12px);opacity:0}20%{opacity:1}50%{transform:translateY(1px)}60%,100%{transform:none;opacity:1}}
  .status-creature :global(.a-hang) {transform-origin:50% 0%;animation:sc-hang 3.4s ease-in-out infinite}
  @keyframes -global-sc-hang {0%,100%{transform:rotate(-5deg)}50%{transform:rotate(5deg)}}
  .status-creature :global(.a-fan) {transform-origin:0% 50%;animation:sc-fan 3.4s ease-in-out infinite}
  @keyframes -global-sc-fan {0%,40%,100%{transform:scaleX(.25)}60%,80%{transform:scaleX(1)}}
  .status-creature :global(.a-peer) {animation:sc-peer 2.8s ease-out infinite}
  @keyframes -global-sc-peer {0%,15%{transform:translateY(3.5px);opacity:.15}60%,100%{transform:none;opacity:1}}
  @media (prefers-reduced-motion: reduce) {
    .status-creature :global(svg *) {
      animation: none !important;
    }
  }
</style>
