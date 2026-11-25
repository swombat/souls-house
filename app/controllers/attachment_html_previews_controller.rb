# Serves a sanitized HTML attachment for the in-conversation sandboxed iframe
# preview. Subclasses ActiveStorage::Blobs::ProxyController so
# HidesDiscardedBlobs and HidesStoneBlobs (prepended in
# active_storage_discard.rb) apply here too: a deleted message's preview is a
# 404, as its download is.
#
# Rendered previews are sanitized server-side through a parser-based allowlist
# (AttachmentHtmlPreviewSanitizer) so links, forms, meta refreshes, scripts,
# and remote URLs are removed even when the preview URL is opened directly.
# CSP `sandbox` (shared with StonesController via SandboxedHtml::CONTENT_POLICY)
# adds a second opaque-origin layer with no scripts, forms, popups, or external
# fetches while keeping inline styles and `data:` images working.
class AttachmentHtmlPreviewsController < ActiveStorage::Blobs::ProxyController

  CONTENT_POLICY = SandboxedHtml::CONTENT_POLICY
  MAX_PREVIEW_BYTES = AttachmentHtmlPreviewSanitizer::MAX_BYTES
  HTML_EXTENSIONS = %w[html htm].freeze

  def self.html_blob?(blob)
    type = blob.content_type.to_s.downcase.split(";").first.to_s.strip
    ext = File.extname(blob.filename.to_s).delete_prefix(".").downcase
    type == "text/html" || HTML_EXTENSIONS.include?(ext)
  end

  def self.previewable_blob?(blob)
    html_blob?(blob) && blob.byte_size.to_i <= MAX_PREVIEW_BYTES
  end

  rescue_from ActiveStorage::FileNotFoundError do
    head :not_found
  end

  rescue_from AttachmentHtmlPreviewSanitizer::TooLarge do
    head :content_too_large
  end

  rescue_from AttachmentHtmlPreviewSanitizer::Invalid do
    head :unprocessable_entity
  end

  def show
    return head :unsupported_media_type unless self.class.html_blob?(@blob)
    return head :content_too_large if @blob.byte_size.to_i > MAX_PREVIEW_BYTES

    sanitized_html = AttachmentHtmlPreviewSanitizer.sanitize(@blob.download)

    response.headers["Content-Security-Policy"] = CONTENT_POLICY
    response.headers["X-Frame-Options"] = "SAMEORIGIN"
    response.headers["Referrer-Policy"] = "no-referrer"
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["Cache-Control"] = "private, no-store"
    response.headers["Content-Disposition"] = "inline"
    render body: sanitized_html, content_type: "text/html; charset=utf-8"
  end

end
