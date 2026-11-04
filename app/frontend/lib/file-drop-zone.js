import { dragHasFiles } from '$lib/file-upload-rules';

// Svelte action: makes an element accept files dragged in from the desktop. While a file drag
// is over it the element carries `data-file-drag` for styling. Drags of text or links inside the
// page are left alone, so selecting and moving text in the textarea still works.
export function fileDropZone(node, params) {
  let { onfiles, disabled = false } = params || {};
  let depth = 0;

  function setActive(active) {
    if (active) node.setAttribute('data-file-drag', '');
    else node.removeAttribute('data-file-drag');
  }

  function enter(event) {
    if (disabled || !dragHasFiles(event.dataTransfer)) return;
    event.preventDefault();
    depth += 1;
    setActive(true);
  }

  function over(event) {
    if (!dragHasFiles(event.dataTransfer)) return;
    // Without this the browser opens the dropped file in the tab, leaving the conversation;
    // a disabled composer still takes the drop, and ignores it.
    event.preventDefault();
    event.dataTransfer.dropEffect = disabled ? 'none' : 'copy';
  }

  function leave(event) {
    if (!dragHasFiles(event.dataTransfer)) return;
    // dragleave fires for every child crossed; only the last one out ends the highlight.
    depth = Math.max(0, depth - 1);
    if (depth === 0) setActive(false);
  }

  function drop(event) {
    if (!dragHasFiles(event.dataTransfer)) return;
    event.preventDefault();
    depth = 0;
    setActive(false);
    if (disabled) return;
    const files = Array.from(event.dataTransfer.files || []);
    if (files.length > 0) onfiles?.(files);
  }

  node.addEventListener('dragenter', enter);
  node.addEventListener('dragover', over);
  node.addEventListener('dragleave', leave);
  node.addEventListener('drop', drop);

  return {
    update(next) {
      ({ onfiles, disabled = false } = next || {});
      if (disabled) {
        depth = 0;
        setActive(false);
      }
    },
    destroy() {
      node.removeEventListener('dragenter', enter);
      node.removeEventListener('dragover', over);
      node.removeEventListener('dragleave', leave);
      node.removeEventListener('drop', drop);
    },
  };
}
