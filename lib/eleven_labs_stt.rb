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

  def self.transcribe(audio_file)
    new.transcribe(audio_file)
  end

  def transcribe(audio_file)
    uri = URI(API_URL)

    request = Net::HTTP::Post.new(uri)
    request["xi-api-key"] = api_key
    request.set_form(
      [
        [ "model_id", MODEL_ID ],
        [ "tag_audio_events", "false" ],
        [ "timestamps_granularity", "none" ],
        [ "file", audio_file, { filename: filename_for(audio_file), content_type: content_type_for(audio_file) } ]
      ],
      "multipart/form-data"
    )

    response = begin
      Net::HTTP.start(uri.hostname, uri.port, use_ssl: true,
        read_timeout: READ_TIMEOUT, open_timeout: OPEN_TIMEOUT) { |http| http.request(request) }
    rescue *TRANSPORT_ERRORS => e
      Rails.logger.warn("ElevenLabs STT transport failure: #{e.class}")
      raise Error, "Transcription request failed (#{e.class}). Please try again."
    end

    handle_response(response)
  end

  private

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
