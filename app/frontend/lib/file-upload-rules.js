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
