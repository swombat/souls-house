# Posts one tweet for a resident to its own account's connected X handle.
#
# The account comes only from the resident (agent.account), never from a
# request parameter. Every post needs an idempotency key: a repeated key
# returns the stored outcome and never posts again. The enabled switch and the
# account's X app are checked under a row lock on the integration, and the
# pending row is written inside that lock, so switching posting off stops
# every post that has not reserved yet. There is no house ceiling on posts:
# the house app is only for accounts with a site admin in them, and every
# other account pays X through its own app. A post whose fate we cannot know (timeout after sending, broken
# connection, 5xx, unreadable 2xx) is stored as outcome_unknown and is never
# retried automatically; someone has to resolve it.
class XPoster

  class Refused < StandardError

    attr_reader :code, :http_status

    def initialize(code, message, http_status)
      @code = code
      @http_status = http_status
      super(message)
    end

  end

  Result = Struct.new(:log, :replayed, keyword_init: true)

  MAX_KEY_LENGTH = 200
  RESERVATION_LOCK_SPACE = 7_316
  TWEET_ID_PATTERN = /\A\d{1,25}\z/

  # Errors raised before any byte of the request is sent: the post cannot
  # have happened.
  CONNECT_ERRORS = [ Net::OpenTimeout, SocketError, SystemCallError, OpenSSL::SSL::SSLError, IOError ].freeze
  # Errors raised while sending or waiting for the answer: X may have posted.
  IN_FLIGHT_ERRORS = [ Net::ReadTimeout, Net::WriteTimeout, EOFError, IOError, SystemCallError, OpenSSL::SSL::SSLError ].freeze

  def initialize(agent:)
    @agent = agent
    @account = agent.account
  end

  def post!(text:, idempotency_key:, reply_to: nil)
    text = text.to_s.strip
    reply_to = reply_to.to_s.strip.presence
    validate!(text:, idempotency_key:, reply_to:)

    log, replayed = reserve!(text:, idempotency_key:, reply_to:)
    return Result.new(log:, replayed: true) if replayed

    send_exclusively!(log) if token_ready?(log)
    Result.new(log: log.reload, replayed: false)
  end

  private

  attr_reader :agent, :account

  def validate!(text:, idempotency_key:, reply_to:)
    if idempotency_key.blank? || idempotency_key.length > MAX_KEY_LENGTH
      raise Refused.new("idempotency_key_required", "An Idempotency-Key header (1-#{MAX_KEY_LENGTH} characters) is required", :bad_request)
    end
    raise Refused.new("text_blank", "Text is empty", :unprocessable_entity) if text.blank?

    length = XTextLength.weighted_length(text)
    if length > XTextLength::MAX_WEIGHTED_LENGTH
      raise Refused.new("text_too_long", "Text is #{length} weighted characters; X allows #{XTextLength::MAX_WEIGHTED_LENGTH}", :unprocessable_entity)
    end
    if reply_to && !reply_to.match?(TWEET_ID_PATTERN)
      raise Refused.new("invalid_reply_to", "reply_to must be a numeric tweet id", :unprocessable_entity)
    end
  end

  def reserve!(text:, idempotency_key:, reply_to:)
    integration = XIntegration.find_by(account_id: account.id)
    raise Refused.new("not_connected", "This account has no connected X handle", :forbidden) unless integration

    digest = Digest::SHA256.hexdigest({ text:, reply_to: }.to_json)

    XIntegration.transaction do
      # Serialises reservations for one account (idempotency, the enabled
      # switch) without taking the integration's row lock, which in-flight
      # sends hold in share mode; a reservation never waits for a send.
      XIntegration.connection.execute(
        XIntegration.sanitize_sql_array([ "SELECT pg_advisory_xact_lock(?, ?)", RESERVATION_LOCK_SPACE, integration.id ])
      )
      integration.reload

      existing = TweetLog.find_by(agent:, idempotency_key:)
      if existing
        unless existing.request_digest == digest
          raise Refused.new("idempotency_key_reused", "This Idempotency-Key was already used for a different post", :unprocessable_entity)
        end
        return [ existing, true ]
      end

      raise Refused.new("not_connected", "This account has no connected X handle", :forbidden) unless integration.connected?
      raise Refused.new("posting_disabled", "Posting to X is turned off for this account", :forbidden) unless integration.enabled?
      unless integration.app_available?
        raise Refused.new("no_x_app", "This account has no X app to post through; an account admin adds one on the X posting page", :forbidden)
      end

      log = integration.tweet_logs.create!(
        agent:, text:, reply_to_tweet_id: reply_to, idempotency_key:,
        request_digest: digest, status: "pending"
      )
      [ log, false ]
    end
  end

  # Under the post's own row lock: if the post is no longer pending (someone
  # resolved a stale reservation), nothing is sent. Touching it restarts the
  # quiet period a resolver must wait out. A stale token is refreshed under
  # the integration's exclusive lock, so two posts never spend one rotating
  # refresh token twice. Returns false when nothing should be sent.
  def token_ready?(log)
    XIntegration.transaction do
      log.lock!
      return false unless log.status == "pending"

      log.touch
      integration = log.x_integration.reload
      unless integration.token_fresh?
        integration.lock!
        raise XApi::Error, "The X connection or its app changed before sending" unless integration.connected? && integration.app_available?

        integration.refresh_tokens!
      end
    end
    true
  rescue XApi::Error, ArgumentError, JSON::ParserError, *CONNECT_ERRORS, Net::ReadTimeout => e
    finish!(log, status: "failed", failure_reason: "token_refresh_failed", error_message: e.message.truncate(500))
    false
  end

  # The post's own row lock is held from the final pending check through the
  # send and the recording of X's answer. A resolver takes the same lock, so
  # it either resolves first (and this sends nothing) or waits and then sees
  # the recorded outcome.
  #
  # The integration row is held in share mode for the same span, and the
  # bearer token is read under it. Changing or removing the app, disconnecting
  # and switching posting off all update that row, so they wait for a send in
  # progress, and a send that starts after them sees the cleared token and
  # sends nothing. Other sends share the lock and run alongside; a token
  # refresh (exclusive) waits for them. At most one send (about 70 seconds)
  # is ever waited for.
  def send_exclusively!(log)
    TweetLog.transaction do
      log.lock!
      next unless log.status == "pending"

      integration = XIntegration.lock("FOR SHARE").find(log.x_integration_id)
      reason = unsendable_reason(integration)
      next finish!(log, status: "failed", failure_reason: reason, error_message: "Nothing was sent: #{reason.tr("_", " ")}") if reason

      deliver!(log, integration.access_token)
    end
  end

  def unsendable_reason(integration)
    return "disconnected" unless integration.connected? && integration.access_token.present?
    return "posting_disabled" unless integration.enabled?
    return "no_x_app" unless integration.app_available?

    nil
  end

  def deliver!(log, access_token)
    uri = URI("#{XApi::X_API_BASE}/tweets")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 10
    http.read_timeout = 30
    http.write_timeout = 30
    http.max_retries = 0

    begin
      http.start
    rescue *CONNECT_ERRORS => e
      return finish!(log, status: "failed", failure_reason: "unreachable", error_message: e.message.truncate(500))
    end

    request = Net::HTTP::Post.new(uri)
    request["Authorization"] = "Bearer #{access_token}"
    request["Content-Type"] = "application/json"
    body = { text: log.text }
    body[:reply] = { in_reply_to_tweet_id: log.reply_to_tweet_id } if log.reply_to_tweet_id
    request.body = body.to_json

    begin
      response = http.request(request)
    rescue *IN_FLIGHT_ERRORS => e
      return unknown!(log, "#{e.class}: #{e.message}")
    ensure
      http.finish if http.started?
    end

    begin
      record_response!(log, response)
    rescue StandardError => e
      # Something after the send went wrong while reading or recording the
      # answer. X may have published: never call that a failure.
      unknown!(log, "Could not record X's answer (#{response.code}): #{e.class}")
    end
  end

  def record_response!(log, response)
    code = response.code.to_i
    data = parse_object(response.body)
    detail = error_detail(data)

    case code
    when 200..299
      payload = data && data["data"]
      tweet_id = payload.is_a?(Hash) ? payload["id"] : nil
      return unknown!(log, "X answered #{code} without a readable tweet id") unless tweet_id.is_a?(String) && tweet_id.match?(TWEET_ID_PATTERN)

      finish!(log, status: "posted", tweet_id:)
    when 401
      finish!(log, status: "failed", failure_reason: "unauthorized", error_message: "X rejected the access token; reconnect the account. #{detail}".strip)
    when 403
      finish!(log, status: "failed", failure_reason: "forbidden", error_message: "X refused the post (missing tweet.write scope, app access level, or duplicate text). #{detail}".strip)
    when 429
      reset = response["x-rate-limit-reset"].to_i
      reset_at = Time.zone.at(reset).iso8601 if reset.positive?
      finish!(log, status: "failed", failure_reason: "rate_limited", error_message: [ "X rate limit reached", (reset_at && "until #{reset_at}"), detail ].compact.join(" ").strip)
    when 400..499
      finish!(log, status: "failed", failure_reason: "rejected", error_message: "X rejected the post (#{code}). #{detail}".strip)
    else
      unknown!(log, "X answered #{code}. #{detail}".strip)
    end
  end

  def unknown!(log, message)
    finish!(log, status: "outcome_unknown", failure_reason: "outcome_unknown", error_message: message.truncate(500))
  end

  # The sender's last write only lands while the row is still pending. Under
  # send_exclusively! a resolution cannot land in between; this stays as a
  # second guard so a resolution is never overwritten if that ever changes.
  def finish!(log, **attributes)
    updated = TweetLog.where(id: log.id, status: "pending").update_all(attributes.merge(updated_at: Time.current))
    return true if updated == 1

    late = "Late answer after resolution: #{attributes.slice(:status, :tweet_id, :error_message).compact.to_json}"
    TweetLog.where(id: log.id).update_all([ "error_message = CONCAT_WS(' | ', error_message, ?), updated_at = ?", late.truncate(500), Time.current ])
    false
  end

  def parse_object(body)
    parsed = JSON.parse(body.to_s)
    parsed.is_a?(Hash) ? parsed : nil
  rescue JSON::ParserError
    nil
  end

  def error_detail(data)
    return "" unless data

    errors = data["errors"].is_a?(Array) ? data["errors"] : []
    messages = errors.map { |error| error.is_a?(Hash) ? (error["message"] || error["detail"]) : nil }
    [ data["title"], data["detail"], *messages ].select { |part| part.is_a?(String) }.uniq.join(": ").truncate(300)
  end

end
