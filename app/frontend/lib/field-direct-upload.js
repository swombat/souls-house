import { DirectUpload } from '@rails/activestorage';

// One Active Storage direct upload for a recording attempt that can be
// abandoned. `current` is the attempt: { cancelled, xhrs, createXhr, fail }.
// DirectUpload hands over each XHR just before sending it; if the attempt was
// abandoned meanwhile (say, during the checksum), that XHR is never sent, and
// the ones already sent are kept on `current.xhrs` so abandoning can abort
// them. `current.fail` rejects the promise from outside. Resolves with the
// blob; rejects with the server's error message, or a plain one.
export function directUpload(file, url, current, onProgress = () => {}) {
  return new Promise((resolve, reject) => {
    current.fail = reject;
    const track = (xhr) => {
      if (current.cancelled) xhr.send = () => {};
      else current.xhrs.push(xhr);
    };
    const delegate = {
      directUploadWillCreateBlobWithXHR: (xhr) => {
        current.createXhr = xhr;
        track(xhr);
      },
      directUploadWillStoreFileWithXHR: (xhr) => {
        track(xhr);
        xhr.upload.addEventListener('progress', (e) => {
          if (e.lengthComputable) onProgress(e.loaded / e.total);
        });
      },
    };
    new DirectUpload(file, url, delegate).create((failure, blob) => {
      if (current.cancelled) return;
      if (failure) reject(current.createXhr?.response?.error || 'The upload stopped. Please try again.');
      else resolve(blob);
    });
  });
}
