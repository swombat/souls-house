# pyannoteAI voiceprints and identification (spec §2, §9). Jobs are async:
# submit returns a job id, and #job is polled. Errors carry our own wording and
# the status code only. Prints and audio never appear in an error or a log.
class PyannoteClient

  class Error < StandardError; end
  class PermanentError < Error; end
  class TransientError < Error; end

  BASE_URL = "https://api.pyannote.ai"
  MODEL = "precision-2"
  TIMEOUT = 30

  def self.api_key
    Rails.application.credentials.dig(:ai, :pyannote, :api_key)
  end

  def self.configured? = api_key.is_a?(String) && api_key.present?

  def voiceprint(url:)
    post("/v1/voiceprint", { url: }).fetch("jobId")
  end

  # voiceprints: [{label:, voiceprint:}] with opaque labels, never names.
  def identify(url:, voiceprints:, threshold:, num_speakers: nil)
    body = { url:, voiceprints:, model: MODEL, matching: { threshold:, exclusive: true } }
    body[:maxSpeakers] = num_speakers if num_speakers
    post("/v1/identify", body).fetch("jobId")
  end

  def job(job_id)
    request(Net::HTTP::Get.new(URI("#{BASE_URL}/v1/jobs/#{CGI.escape(job_id)}")))
  end

  private

  def post(path, body)
    request = Net::HTTP::Post.new(URI("#{BASE_URL}#{path}"))
    request["Content-Type"] = "application/json"
    request.body = body.to_json
    result = request(request)
    raise TransientError, "pyannote returned no job id" unless result.is_a?(Hash) && result["jobId"].is_a?(String)

    result
  end

  def request(request)
    key = self.class.api_key
    raise PermanentError, "pyannote is not configured" unless key.is_a?(String) && key.present?

    request["Authorization"] = "Bearer #{key}"
    uri = request.uri
    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: TIMEOUT, read_timeout: TIMEOUT) do |http|
      http.request(request)
    end
    code = response.code.to_i
    raise TransientError, "pyannote returned #{code}" if code == 429 || code >= 500
    raise PermanentError, "pyannote refused the request (#{code})" unless code.between?(200, 299)

    parsed = JSON.parse(response.body.to_s)
    raise TransientError, "pyannote returned an unreadable body" unless parsed.is_a?(Hash)

    parsed
  rescue *ElevenLabsStt::TRANSPORT_ERRORS => e
    raise TransientError, "pyannote transport failure (#{e.class})"
  rescue JSON::ParserError
    raise TransientError, "pyannote returned an unreadable body"
  end

end
