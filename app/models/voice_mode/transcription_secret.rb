require "net/http"

# A short-lived OpenAI Realtime client secret for one voice-mode session
# (YgDwre design, YMaddY build). The browser uses it to open a transcription
# WebSocket straight to OpenAI; the account's key never leaves the server.
#
# The session is configured here, not by the browser: gpt-live-transcribe,
# 24 kHz PCM, no server turn detection (the page's own detector commits each
# turn), and the account glossary as keywords. A secret only opens sessions;
# an open session outlives it, so the lifetime is short and the page asks for
# a fresh one each time it (re)connects.
#
# No audio passes through the house and none is kept: voice-mode messages are
# text, flagged as spoken.
class VoiceMode::TranscriptionSecret

  class Error < StandardError; end

  API_URL = "https://api.openai.com/v1/realtime/client_secrets".freeze
  SOCKET_URL = "wss://api.openai.com/v1/realtime?intent=transcription".freeze
  MODEL = "gpt-live-transcribe".freeze
  DELAY = "low".freeze
  SAMPLE_RATE = 24_000
  LIFETIME_SECONDS = 120
  OPEN_TIMEOUT = 5
  READ_TIMEOUT = 15
  MAX_KEYWORDS = 100
  # OpenAI refuses a session whose keywords contain these.
  KEYWORD_FORBIDDEN = /[<>\r\n]/
  KEYWORD_REFUSAL_CODES = [ 400, 422 ].freeze

  TRANSPORT_ERRORS = [
    Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, EOFError, IOError,
    SocketError, OpenSSL::SSL::SSLError, SystemCallError
  ].freeze

  Result = Struct.new(:client_secret, :expires_at, :model, :socket_url, :sample_rate, keyword_init: true) do
    def as_json(*)
      { "client_secret" => client_secret, "expires_at" => expires_at, "model" => model,
        "socket_url" => socket_url, "sample_rate" => sample_rate }
    end
  end

  def self.mint(account)
    new(account).mint
  end

  # keywords: the glossary's by default.
  def initialize(account, keywords: nil)
    @account = account
    @keywords = keywords
  end

  def mint
    key = @account.ai_api_key(VoiceMode::TRANSCRIPTION_PROVIDER)
    raise Error, "No OpenAI API key is set for this account." if key.blank?

    keywords = @keywords || self.class.keywords_for(@account)
    response = post(key, keywords)
    if keywords.any? && KEYWORD_REFUSAL_CODES.include?(response.code.to_i)
      Rails.logger.warn("[VoiceMode] OpenAI refused a session with #{keywords.size} keywords (#{response.code}); retrying without them")
      response = post(key, [])
    end
    handle(response)
  end

  # The glossary's terms, in its priority order, as OpenAI will take them.
  def self.keywords_for(account)
    TranscriptionGlossary.keyterms_for(account)
      .map { |term| term.to_s.strip }
      .reject { |term| term.empty? || term.match?(KEYWORD_FORBIDDEN) }
      .uniq
      .first(MAX_KEYWORDS)
  end

  def self.session_config(keywords: [])
    transcription = { model: MODEL, delay: DELAY }
    transcription[:keywords] = keywords if keywords.any?
    {
      type: "transcription",
      audio: {
        input: {
          format: { type: "audio/pcm", rate: SAMPLE_RATE },
          noise_reduction: { type: "near_field" },
          transcription: transcription,
          turn_detection: nil
        }
      }
    }
  end

  private

  def post(key, keywords)
    uri = URI(API_URL)
    request = Net::HTTP::Post.new(uri)
    request["Authorization"] = "Bearer #{key}"
    request["Content-Type"] = "application/json"
    request.body = {
      expires_after: { anchor: "created_at", seconds: LIFETIME_SECONDS },
      session: self.class.session_config(keywords:)
    }.to_json

    Net::HTTP.start(uri.hostname, uri.port, use_ssl: true,
      open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) { |http| http.request(request) }
  rescue *TRANSPORT_ERRORS => e
    Rails.logger.warn("[VoiceMode] OpenAI client secret transport failure: #{e.class}")
    raise Error, "Could not reach OpenAI to start transcription. Try again."
  end

  def handle(response)
    body = JSON.parse(response.body.presence || "{}") rescue {}
    case response.code.to_i
    when 200
      secret = body["value"].presence || body.dig("client_secret", "value").presence
      raise Error, "OpenAI did not return a transcription secret." unless secret

      Result.new(client_secret: secret, expires_at: body["expires_at"], model: MODEL,
        socket_url: SOCKET_URL, sample_rate: SAMPLE_RATE)
    when 401
      raise Error, "The OpenAI API key was refused."
    when 429
      raise Error, "OpenAI is rate limiting or the key is out of credit."
    else
      detail = body.dig("error", "message").to_s.truncate(200)
      Rails.logger.warn("[VoiceMode] OpenAI client secret failed (#{response.code}): #{detail}")
      raise Error, "OpenAI could not start transcription (#{response.code})."
    end
  end

end
