class ElevenLabsTts

  class Error < StandardError; end

  API_BASE = "https://api.elevenlabs.io/v1/text-to-speech"
  MODEL_ID = "eleven_v3"
  READ_TIMEOUT = 60
  OPEN_TIMEOUT = 10

  # How the connection to ElevenLabs can fail mid-request. In a stream these
  # become Error, so the caller can answer 502 rather than an empty 200; an
  # error raised by the caller's own block (the browser going away) is not ours.
  TRANSPORT_ERRORS = [
    Net::OpenTimeout, Net::ReadTimeout, Net::HTTPBadResponse, SocketError,
    SystemCallError, EOFError, OpenSSL::SSL::SSLError
  ].freeze

  DEFAULT_VOICE_SETTINGS = {
    stability: 0.5,
    similarity_boost: 0.75,
    style: 0.0,
    use_speaker_boost: true,
    speed: 1.0
  }.freeze

  def self.synthesize(text, voice_id:)
    new.synthesize(text, voice_id: voice_id)
  end

  def synthesize(text, voice_id:)
    uri = URI("#{API_BASE}/#{voice_id}")
    request = build_request(uri, text)

    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true,
      read_timeout: READ_TIMEOUT, open_timeout: OPEN_TIMEOUT) { |http| http.request(request) }

    handle_response(response)
  end

  def self.stream(text, voice_id:, &block)
    new.stream(text, voice_id: voice_id, &block)
  end

  # Voice mode: the audio arrives in chunks as ElevenLabs makes it, so playback
  # can start at the first one (about half a second on eleven_v3, against two or
  # more for the whole file). A refusal raises before anything is yielded.
  def stream(text, voice_id:)
    uri = URI("#{API_BASE}/#{voice_id}/stream?output_format=mp3_44100_128")
    request = build_request(uri, text)
    in_caller = false

    Net::HTTP.start(uri.hostname, uri.port, use_ssl: true,
      read_timeout: READ_TIMEOUT, open_timeout: OPEN_TIMEOUT) do |http|
      http.request(request) do |response|
        handle_response(response) unless response.code.to_i == 200
        response.read_body do |chunk|
          in_caller = true
          yield chunk
          in_caller = false
        end
      end
    end
  rescue *TRANSPORT_ERRORS => e
    raise if in_caller

    raise Error, "ElevenLabs stream failed: #{e.class}: #{e.message}"
  end

  private

  def build_request(uri, text)
    request = Net::HTTP::Post.new(uri)
    request["xi-api-key"] = api_key
    request["Content-Type"] = "application/json"
    request["Accept"] = "audio/mpeg"
    request.body = {
      text: text,
      model_id: MODEL_ID,
      voice_settings: DEFAULT_VOICE_SETTINGS
    }.to_json
    request
  end

  def api_key
    Rails.application.credentials.dig(:ai, :eleven_labs, :api_token) ||
      raise(Error, "ElevenLabs API key not configured")
  end

  def handle_response(response)
    case response.code.to_i
    when 200
      response.body
    when 401
      raise Error, "Invalid ElevenLabs API key"
    when 429
      raise Error, "ElevenLabs rate limit exceeded. Please try again later."
    when 422
      error_msg = JSON.parse(response.body).dig("detail", "message") rescue "Invalid request"
      raise Error, "Speech synthesis failed: #{error_msg}"
    else
      Rails.logger.error("ElevenLabs TTS error: #{response.code} - #{response.body}")
      raise Error, "Speech synthesis service unavailable. Please try again."
    end
  end

end
