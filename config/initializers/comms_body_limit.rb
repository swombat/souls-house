# The comms connector's event endpoint takes bounded bodies. The bound is
# enforced here, in front of the app, so it holds before any parser, params
# access or logging can read the body, whatever they turn out to be. Answers 413
# (too large) or 411 (no declared length) for that path alone.
class CommsBodyLimit

  PATH_PREFIX = "/internal/comms/".freeze

  def initialize(app)
    @app = app
  end

  def call(env)
    return @app.call(env) unless env["PATH_INFO"].to_s.start_with?(PATH_PREFIX) && env["REQUEST_METHOD"] == "POST"

    length = env["CONTENT_LENGTH"]
    return refuse(411, "length_required") if length.nil? || !length.match?(/\A\d+\z/)
    return refuse(413, "body_too_large") if length.to_i > CommsSignature::MAX_BODY_BYTES

    @app.call(env)
  end

  private

  def refuse(status, code)
    [ status, { "content-type" => "application/json" }, [ %({"error":"#{code}"}) ] ]
  end

end

Rails.application.config.middleware.insert_before 0, CommsBodyLimit
