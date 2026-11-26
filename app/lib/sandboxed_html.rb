# Shared Content-Security-Policy for sandboxed static HTML responses (public
# stones and in-conversation HTML attachment previews). Enforces an opaque
# origin with no scripts, forms, popups, or external fetches while still
# allowing inline styles and data: images.
module SandboxedHtml

  CONTENT_POLICY = [
    "sandbox",
    "default-src 'none'",
    "script-src 'none'",
    "style-src 'unsafe-inline'",
    "img-src data:",
    "font-src 'none'",
    "connect-src 'none'",
    "object-src 'none'",
    "frame-src 'none'",
    "worker-src 'none'",
    "base-uri 'none'",
    "form-action 'none'",
    "frame-ancestors 'self'"
  ].join("; ").freeze

end
