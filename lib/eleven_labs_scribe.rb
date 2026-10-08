# Asynchronous Scribe v2 transcription with diarization, for Field recordings
# (spec §2, §5). Separate from ElevenLabsStt, which stays synchronous for
# voice notes. Errors carry status codes only, never transcript content.
class ElevenLabsScribe

  class Error < StandardError; end
  class PermanentError < Error; end # 4xx other than 429: don't retry
  class TransientError < Error; end # 429, 5xx, transport: retry within the cap

  BASE_URL = "https://api.elevenlabs.io"
  MODEL_ID = "scribe_v2"
  OPEN_TIMEOUT = 10
  READ_TIMEOUT = 120

  Submission = Struct.new(:request_id, :transcription_id, keyword_init: true)

  # Starts an async transcription. Exactly one of source_url / file.
  def submit(metadata:, source_url: nil, file: nil, num_speakers: nil)
    form = [
      [ "model_id", MODEL_ID ],
      [ "diarize", "true" ],
      [ "timestamps_granularity", "word" ],
      [ "tag_audio_events", "true" ],
      [ "webhook", "true" ],
      [ "webhook_metadata", metadata.to_json ]
    ]
    form << [ "webhook_id", webhook_id ] if webhook_id.present?
    form << [ "num_speakers", num_speakers.to_s ] if num_speakers
    if source_url
      form << [ "cloud_storage_url", source_url ]
    else
      form << [ "file", file, { filename: "recording", content_type: "application/octet-stream" } ]
    end

    request = Net::HTTP::Post.new(URI("#{BASE_URL}/v1/speech-to-text"))
    request.set_form(form, "multipart/form-data")
    body = perform(request, expect: [ 200, 202 ])
    Submission.new(request_id: body["request_id"].presence, transcription_id: body["transcription_id"].presence)
  end

  def fetch(transcription_id)
    perform(Net::HTTP::Get.new(URI("#{BASE_URL}/v1/speech-to-text/transcripts/#{CGI.escape(transcription_id)}")), expect: [ 200 ])
  end

  def delete(transcription_id)
    perform(Net::HTTP::Delete.new(URI("#{BASE_URL}/v1/speech-to-text/transcripts/#{CGI.escape(transcription_id)}")),
      expect: [ 200, 204, 404 ])
    true
  end

  # ElevenLabs-Signature: "t=<unix seconds>,v0=<hex hmac-sha256(secret, "t.body")>",
  # as their SDKs' construct_event checks it, with the SDK's 30-minute window.
  def self.valid_signature?(header, body, secret:, now: Time.current)
    return false if header.blank? || secret.blank?

    parts = header.split(",").to_h { |part| part.split("=", 2) }
    timestamp, signature = parts["t"], parts["v0"]
    return false unless timestamp&.match?(/\A\d+\z/) && signature.present?

    sent_at = Time.at(timestamp.to_i)
    return false if sent_at < now - 30.minutes || sent_at > now + 5.minutes

    expected = OpenSSL::HMAC.hexdigest("SHA256", secret, "#{timestamp}.#{body}")
    ActiveSupport::SecurityUtils.secure_compare(expected, signature)
  end

  def self.webhook_secret
    Rails.application.credentials.dig(:ai, :eleven_labs, :stt_webhook_secret)
  end

  private

  def perform(request, expect:)
    request["xi-api-key"] = api_key
    uri = request.uri
    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true,
      open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) { |http| http.request(request) }
    code = response.code.to_i

    unless expect.include?(code)
      raise TransientError, "Scribe returned #{code}" if code == 429 || code >= 500

      raise PermanentError, "Scribe returned #{code}: #{vendor_message(response)}"
    end
    return {} if response.body.blank?

    JSON.parse(response.body)
  rescue *ElevenLabsStt::TRANSPORT_ERRORS => e
    raise TransientError, "Scribe transport failure (#{e.class})"
  rescue JSON::ParserError
    raise TransientError, "Scribe returned an unreadable body"
  end

  # A short vendor reason for a refused request (e.g. "file too long"). Never
  # the request or transcript body.
  def vendor_message(response)
    data = JSON.parse(response.body.to_s)
    message = data.dig("detail", "message") || data.dig("error", "message") || data["detail"]
    message.is_a?(String) ? message.truncate(200) : "request refused"
  rescue JSON::ParserError
    "request refused"
  end

  def api_key
    Rails.application.credentials.dig(:ai, :eleven_labs, :api_token) || raise(PermanentError, "ElevenLabs API key not configured")
  end

  def webhook_id
    Rails.application.credentials.dig(:ai, :eleven_labs, :stt_webhook_id)
  end

end
