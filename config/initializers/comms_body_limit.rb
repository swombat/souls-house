# The comms connector's event endpoint takes bounded bodies. The bound has to
# hold before Rails touches the body: start-of-request parameter logging and
# params access parse JSON before any controller callback can refuse it. So
# this sits in front of the app and answers 413 (too large) or 411 (no
# declared length) for that path alone.
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
