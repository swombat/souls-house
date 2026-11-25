# Serves an HTML attachment for the in-conversation sandboxed iframe preview.
# Subclasses ActiveStorage::Blobs::ProxyController so HidesDiscardedBlobs and
# HidesStoneBlobs (prepended in active_storage_discard.rb) apply here too: a
# deleted message's preview is a 404, as its download is.
#
# CSP `sandbox` (with no allow-* tokens) enforces an opaque origin with no
# scripts, forms, popups, or top-level navigation even if someone opens the
# preview URL directly in a new tab. External fetches are blocked by
# `default-src 'none'`; inline styles and `data:` images remain allowed.
class AttachmentHtmlPreviewsController < ActiveStorage::Blobs::ProxyController

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

  HTML_EXTENSIONS = %w[html htm].freeze

  def self.html_blob?(blob)
    type = blob.content_type.to_s.downcase.split(";").first.to_s.strip
    ext = File.extname(blob.filename.to_s).delete_prefix(".").downcase
    type == "text/html" || HTML_EXTENSIONS.include?(ext)
  end

  rescue_from ActiveStorage::FileNotFoundError do
    head :not_found
  end

  def show
    return head :unsupported_media_type unless self.class.html_blob?(@blob)

    response.headers["Content-Security-Policy"] = CONTENT_POLICY
    response.headers["X-Frame-Options"] = "SAMEORIGIN"
    response.headers["Referrer-Policy"] = "no-referrer"
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["Cache-Control"] = "private, no-store"
    response.headers["Content-Disposition"] = "inline"
    render body: @blob.download, content_type: "text/html; charset=utf-8"
  end

end
