// Download every file in a message without building a zip. Each file's
// `url` is a same-origin blob path served with Content-Disposition:
// attachment, so clicking a hidden anchor saves it without navigating.
// The clicks are spaced out because browsers drop or merge back-to-back
// programmatic downloads; Chrome asks once per site to allow them.
export const DOWNLOAD_GAP_MS = 400;

export function downloadAll(files, { gapMs = DOWNLOAD_GAP_MS, doc = document, schedule = setTimeout } = {}) {
  const queue = (files || []).filter((file) => file && file.url);
  queue.forEach((file, index) => {
    schedule(() => {
      const link = doc.createElement('a');
      link.href = file.url;
      link.download = file.filename || '';
      link.rel = 'noopener';
      link.style.display = 'none';
      doc.body.appendChild(link);
      link.click();
      link.remove();
    }, index * gapMs);
  });
  return queue.length;
}
