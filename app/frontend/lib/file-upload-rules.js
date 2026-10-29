export function validateUploadFile(file, { maxSize }) {
  if (file.size > maxSize) {
    return `File too large. Maximum size is ${maxSize / (1024 * 1024)}MB.`;
  }

  return null;
}

export function addUploadFiles(files, selectedFiles, options) {
  const { maxFiles } = options;

  if (files.length + selectedFiles.length > maxFiles) {
    return { files, error: `Maximum ${maxFiles} files allowed.` };
  }

  for (const file of selectedFiles) {
    const validationError = validateUploadFile(file, options);
    if (validationError) return { files, error: validationError };
  }

  return { files: [...files, ...selectedFiles], error: null };
}

export function removeUploadFile(files, index) {
  return files.filter((_, i) => i !== index);
}

export function formatFileSize(bytes) {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

// True when a drag carries files from the desktop, not text or a link dragged inside the page.
export function dragHasFiles(dataTransfer) {
  return Array.from(dataTransfer?.types || []).includes('Files');
}

function pad(number) {
  return String(number).padStart(2, '0');
}

// Browsers name every pasted screenshot "image.png"; give each a distinct, dated name so two
// pastes in one message can be told apart in the attachment list and in the conversation.
export function namePastedFile(file, index = 0, now = new Date()) {
  const generic = !file.name || /^image\.\w+$/i.test(file.name);
  if (!generic) return file;

  const extension = (file.type.split('/')[1] || 'png').replace('jpeg', 'jpg').replace(/\+.*$/, '');
  const stamp =
    `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())} ` +
    `${pad(now.getHours())}.${pad(now.getMinutes())}.${pad(now.getSeconds())}`;
  const suffix = index > 0 ? ` (${index + 1})` : '';
  return new File([file], `Pasted ${stamp}${suffix}.${extension}`, {
    type: file.type,
    lastModified: file.lastModified,
  });
}

// Files to attach from a paste, or [] when the paste should stay ordinary text. When the
// clipboard also carries plain text (a spreadsheet range, a file copied in Finder) the person
// meant the text, and the image is only the app's rendering of it.
export function filesFromPaste(clipboardData, now = new Date()) {
  if (!clipboardData) return [];
  if (Array.from(clipboardData.types || []).includes('text/plain')) return [];

  const files = Array.from(clipboardData.items || [])
    .filter((item) => item.kind === 'file')
    .map((item) => item.getAsFile())
    .filter(Boolean);
  return files.map((file, index) => namePastedFile(file, index, now));
}
