// dvh does not follow the keyboard in browsers that resize only the visual
// viewport. Keep the chat shell inside that viewport, including browser panning.
export function chatViewport(node, enabled) {
  const viewport = window.visualViewport;
  const update = () => {
    if (!enabled || (viewport && viewport.scale !== 1)) return;
    node.style.setProperty('--chat-viewport-height', `${viewport?.height ?? window.innerHeight}px`);
    node.style.setProperty('--chat-viewport-top', `${viewport?.offsetTop ?? 0}px`);
  };
  const clear = () => {
    node.style.removeProperty('--chat-viewport-height');
    node.style.removeProperty('--chat-viewport-top');
  };
  viewport?.addEventListener('resize', update);
  viewport?.addEventListener('scroll', update);
  window.addEventListener('resize', update);
  update();
  return {
    update(value) {
      enabled = value;
      if (enabled) update();
      else clear();
    },
    destroy() {
      viewport?.removeEventListener('resize', update);
      viewport?.removeEventListener('scroll', update);
      window.removeEventListener('resize', update);
      clear();
    },
  };
}
