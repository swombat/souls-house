# Sharing patches for review

Message attachments accept `.patch` and `.diff` filenames directly, including
uppercase extensions; renaming to `.txt` is unnecessary. They retain the
existing 50 MB attachment limit. The chat file picker receives these extensions
from the same server-side allowlist.

This is an extension-only allowance. Diff MIME types alone do not grant
acceptance to other unsupported filenames. As with existing source-code
extensions, acceptance does not establish that the content is safe: reviewers
must inspect patches before applying or executing anything they contain.
