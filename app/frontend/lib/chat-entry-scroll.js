// Only entry owns this brief layout-settling window. Reading history or sending
// messages must not acquire a standing bottom pin.
export function pinConversationEntry(container, duration = 2000) {
  let active = true;
  let lastTop;
  let timer;
  const content = container.firstElementChild;
  const inputs = ['wheel', 'touchstart', 'pointerdown', 'keydown'];
  const observer = new ResizeObserver(() => {
    if (active) snap();
  });

  function snap() {
    container.scrollTo({ top: container.scrollHeight, behavior: 'instant' });
    lastTop = container.scrollTop;
  }

  function release() {
    active = false;
    clearTimeout(timer);
    observer.disconnect();
    inputs.forEach((event) => container.removeEventListener(event, release));
    container.removeEventListener('scroll', readerScrolled);
  }

  function readerScrolled() {
    // Our jump, the timeline follower and browser anchoring can all scroll.
    // Keep following if still at the bottom; only movement away releases.
    if (container.scrollTop === lastTop) return;
    if (container.scrollHeight - container.clientHeight - container.scrollTop <= 2) {
      lastTop = container.scrollTop;
    } else {
      release();
    }
  }

  snap();
  if (content) observer.observe(content, { box: 'border-box' });
  observer.observe(container);
  inputs.forEach((event) => container.addEventListener(event, release, { passive: true }));
  container.addEventListener('scroll', readerScrolled);
  timer = setTimeout(release, duration);
  return release;
}
