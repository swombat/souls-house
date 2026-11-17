// The jump-to-mention button's walk: `list` is oldest first. With no current
// target (or one since dismissed) go to the newest; otherwise one older;
// from the oldest, round to the newest again.
export function nextMentionTarget(list, current) {
  if (!list?.length) return null;
  const index = current ? list.indexOf(current) : -1;
  return index <= 0 ? list[list.length - 1] : list[index - 1];
}

export function findMentionElement(root, target) {
  return (
    [...root.querySelectorAll('[data-reply-attention-target]')].find(
      (element) => element.dataset.replyAttentionTarget === target
    ) ?? null
  );
}
