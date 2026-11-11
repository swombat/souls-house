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

  # A write carries the stone's write key in X-Stone-Write-Key and no
  # cookie (this controller never loads a session), so there is no session for
  # a forged request to borrow.
  skip_forgery_protection only: :write
  rate_limit to: 30, within: 1.minute, only: :write, by: -> { request.env["souls_house.stone_name"].to_s },
    with: -> { render json: { error: "Too many writes from this stone; wait a minute" }, status: :too_many_requests }

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
    # Only the trusted viewer may fetch the revision's table data, and only
    # from its own origin; the authored frame keeps connect-src 'none'.
    @reads_tables = @interactive && @revision.field_tables.kept.exists?
    response.headers["Content-Security-Policy"] = [
      "default-src 'none'", @interactive ? "script-src 'nonce-#{@viewer_nonce}'" : "script-src 'none'", "style-src 'unsafe-inline'",
      ("connect-src 'self'" if @reads_tables),
      "frame-src 'self'", "base-uri 'none'", "form-action 'none'",
      "frame-ancestors 'none'"
    ].compact.join("; ")
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
    html = @revision.html_document
    if @revision.interactive? && @revision.field_tables.kept.exists?
      html = FieldTableStoneShim.inject(html, @revision, params[:k])
    end
    render body: html, content_type: "text/html; charset=utf-8"
  end

  # The rows of the tables this exact revision reads, for the trusted viewer
  # to hand into the frame. Bound to the stone (by hostname) and the revision
  # (by number); never an account-wide door. Only interactive, hosted
  # revisions read tables; anything else is 404.
  def data
    raise ActiveRecord::RecordNotFound unless hosted? && @revision.interactive?

    payload = @revision.field_table_payload
    raise ActiveRecord::RecordNotFound if payload.empty?

    response.headers["Content-Security-Policy"] = "sandbox; default-src 'none'"
    render json: { tables: payload }
  end

  # One row appended to a table this exact revision reads, by whoever holds
  # the stone's write link. Only the trusted viewer calls this: it read the
  # key from the link's fragment, and the authored frame never sees it.
  def write
    raise ActiveRecord::RecordNotFound unless hosted? && @revision.interactive?

    response.headers["Content-Security-Policy"] = "sandbox; default-src 'none'"
    key = request.headers["X-Stone-Write-Key"].to_s[/\A[A-Za-z0-9_-]{20,128}\z/]
    unless @stone.write_key_matches?(key)
      return render json: { error: "This link can't write to tables (no write key, or it was revoked)" }, status: :forbidden
    end

    name = params[:table]
    table = @revision.field_tables.kept.find_by(name: name) if name.is_a?(String)
    return render json: { error: "This stone doesn't read a table called #{name.to_s.truncate(80)}" }, status: :not_found unless table

    row = params[:row]
    row = row.to_unsafe_h if row.respond_to?(:to_unsafe_h)
    raise FieldTable::Refused, "row must be an object of column => value" unless row.is_a?(Hash)

    created = table.add_rows!([ row ], by: @stone).first
    render json: { row: created.data }, status: :created
  rescue FieldTable::Refused => e
    render json: { error: e.message }, status: :unprocessable_entity
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
