# Deliberately outside ApplicationController: public stones never load a house
# session, account, navigation props, or conversation transcript.
class StonesController < ActionController::Base

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

  before_action :secure_response
  before_action :find_revision
  helper_method :hosted?

  rescue_from ActiveRecord::RecordNotFound, with: :not_found
  rescue_from Stone::Withdrawn, with: :not_found
  rescue_from ActiveStorage::FileNotFoundError, with: :not_found
  rescue_from StoneAddress::Exhausted do
    render plain: "Stone address temporarily unavailable", status: :service_unavailable
  end

  def show
    if StoneHosting.domain && !hosted?
      return redirect_to @stone.public_url(number: params[:number]), allow_other_host: true
    end
    raise ActiveRecord::RecordNotFound if @revision.interactive? && !hosted?

    @viewer_nonce = SecureRandom.base64(24)
    @interactive = @revision.interactive? && hosted?
    response.headers["Content-Security-Policy"] = [
      "default-src 'none'", @interactive ? "script-src 'nonce-#{@viewer_nonce}'" : "script-src 'none'", "style-src 'unsafe-inline'",
      "frame-src 'self'", "base-uri 'none'", "form-action 'none'",
      "frame-ancestors 'none'"
    ].join("; ")
    @latest = @stone.stone_revisions.order(number: :desc).first
    render layout: false
  end

  def content
    # CSP sandbox makes even a directly opened response an opaque origin.
    # Scripts are only granted for explicitly interactive, separately hosted editions.
    if @revision.interactive?
      raise ActiveRecord::RecordNotFound unless hosted?

      response.headers["Content-Security-Policy"] = CONTENT_POLICY
        .sub("sandbox;", "sandbox allow-scripts;")
        .sub("script-src 'none'", "script-src 'unsafe-inline'")
    else
      response.headers["Content-Security-Policy"] = CONTENT_POLICY
    end
    response.headers["X-Frame-Options"] = "SAMEORIGIN"
    response.headers["Content-Disposition"] = "inline"
    render body: @revision.html_document, content_type: "text/html; charset=utf-8"
  end

  private

  def secure_response
    response.headers["Cache-Control"] = "no-store"
    response.headers["Referrer-Policy"] = "no-referrer"
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["Permissions-Policy"] = "camera=(), microphone=(), geolocation=(), payment=(), usb=(), display-capture=(), clipboard-read=(), clipboard-write=(), fullscreen=(), midi=(), serial=(), bluetooth=(), publickey-credentials-get=()"
    response.headers["Cross-Origin-Resource-Policy"] = "same-origin"
    response.headers["X-Frame-Options"] = "DENY"
    response.headers["X-Robots-Tag"] = "noindex, nofollow"
  end

  def find_revision
    @stone = if hosted?
      StoneAddress.find_by!(name: request.env["souls_house.stone_name"]).stone || raise(ActiveRecord::RecordNotFound)
    else
      Stone.find_by!(public_token: params[:stone_id] || params[:id])
    end
    raise ActiveRecord::RecordNotFound if @stone.withdrawn_at? || @stone.chat.discarded?

    @revision = if params[:number]
      @stone.stone_revisions.find_by!(number: params[:number])
    else
      @stone.stone_revisions.order(number: :desc).first!
    end
    raise ActiveRecord::RecordNotFound unless @revision.html.attached?
  end

  def hosted?
    request.env["souls_house.stone_name"].present?
  end

  def not_found
    render plain: "Stone not found or withdrawn", status: :not_found
  end

end
