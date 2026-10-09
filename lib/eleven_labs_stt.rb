class ElevenLabsStt

  class Error < StandardError; end

  API_URL = "https://api.elevenlabs.io/v1/speech-to-text"
  MODEL_ID = "scribe_v2"
  READ_TIMEOUT = 60
  OPEN_TIMEOUT = 10

  # Callers can keep raw media usable when transcription transport fails.
  TRANSPORT_ERRORS = [
    Net::OpenTimeout,
    Net::ReadTimeout,
    Net::WriteTimeout,
    EOFError,
    IOError,
    SocketError,
    OpenSSL::SSL::SSLError,
    SystemCallError
  ].freeze

  # A refusal of the request as malformed. With keyterms on it, the request
  # is sent once more without them, so a glossary ElevenLabs won't take can
  # never cost anyone their transcription.
  KEYTERM_REFUSAL_CODES = [ 400, 422 ].freeze

  # `keyterms`: the account glossary's bias list (TranscriptionGlossary),
  # sent as one repeated form field per term. Empty sends nothing.
  def self.transcribe(audio_file, keyterms: [])
    new.transcribe(audio_file, keyterms:)
  end

  def transcribe(audio_file, keyterms: [])
    keyterms = Array(keyterms)
    response = post(audio_file, keyterms)
    if keyterms.any? && KEYTERM_REFUSAL_CODES.include?(response.code.to_i)
      Rails.logger.warn("ElevenLabs STT refused a request with #{keyterms.size} keyterms (#{response.code}); retrying without them")
      audio_file.rewind if audio_file.respond_to?(:rewind)
      response = post(audio_file, [])
    end

    handle_response(response)
  end

  # The multipart fields, one "keyterms" field per term.
  def form_fields(audio_file, keyterms: [])
    form = [
      [ "model_id", MODEL_ID ],
      [ "tag_audio_events", "false" ],
      [ "timestamps_granularity", "none" ]
    ]
    Array(keyterms).each { |term| form << [ "keyterms", term ] }
    form << [ "file", audio_file, { filename: filename_for(audio_file), content_type: content_type_for(audio_file) } ]
  end

  private

  def post(audio_file, keyterms)
    uri = URI(API_URL)
    request = Net::HTTP::Post.new(uri)
    request["xi-api-key"] = api_key
    request.set_form(form_fields(audio_file, keyterms:), "multipart/form-data")

    Net::HTTP.start(uri.hostname, uri.port, use_ssl: true,
      read_timeout: READ_TIMEOUT, open_timeout: OPEN_TIMEOUT) { |http| http.request(request) }
  rescue *TRANSPORT_ERRORS => e
    Rails.logger.warn("ElevenLabs STT transport failure: #{e.class}")
    raise Error, "Transcription request failed (#{e.class}). Please try again."
  end

  def api_key
    Rails.application.credentials.dig(:ai, :eleven_labs, :api_token) ||
      raise(Error, "ElevenLabs API key not configured")
  end

  def filename_for(audio_file)
    audio_file.respond_to?(:original_filename) ? audio_file.original_filename : "audio.webm"
  end

  def content_type_for(audio_file)
    audio_file.respond_to?(:content_type) ? audio_file.content_type : "audio/webm"
  end

  def handle_response(response)
    case response.code.to_i
    when 200
      data = begin
        JSON.parse(response.body)
      rescue JSON::ParserError
        raise Error, "Transcription service returned an unreadable body."
      end
      unless data.is_a?(Hash) && (data["text"].nil? || data["text"].is_a?(String))
        raise Error, "Transcription service returned an invalid response."
      end
      text = data["text"]&.strip
      text.presence
    when 401
      raise Error, "Invalid ElevenLabs API key"
    when 429
      raise Error, "ElevenLabs rate limit exceeded. Please try again later."
    when 422
      error_msg = JSON.parse(response.body).dig("error", "message") rescue "Invalid request"
      raise Error, "Transcription failed: #{error_msg}"
    else
      Rails.logger.error("ElevenLabs STT error: #{response.code} - #{response.body}")
      raise Error, "Transcription service unavailable. Please try again."
    end
  end

end
