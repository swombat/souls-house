# Repository webhook deliveries are bounded before any parser, params access
# or logging can read the body (the same pattern as CommsBodyLimit). Answers
# 413 (too large) or 411 (no declared length) for that path alone. GitHub
# always declares the length; workflow_run payloads are tens of kilobytes.
class RepositoryWebhookBodyLimit

  PATH_PREFIX = "/webhooks/repositories/".freeze
  MAX_BODY_BYTES = 1.megabyte

  def initialize(app)
    @app = app
  end

  def call(env)
    return @app.call(env) unless env["PATH_INFO"].to_s.start_with?(PATH_PREFIX) && env["REQUEST_METHOD"] == "POST"

    length = env["CONTENT_LENGTH"].to_s
    return refuse(411, "length_required") unless length.match?(/\A\d+\z/)
    return refuse(413, "body_too_large") if length.to_i > MAX_BODY_BYTES

    @app.call(env)
  end

  private

  def refuse(status, code)
    [ status, { "content-type" => "application/json" }, [ %({"error":"#{code}"}) ] ]
  end

end

Rails.application.config.middleware.insert_before 0, RepositoryWebhookBodyLimit
