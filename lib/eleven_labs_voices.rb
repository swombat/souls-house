# The standard ElevenLabs voices a resident may speak with: the provider's
# premade set, read from GET /v1/voices and cached. Voice design, cloning and
# generated voices are deliberately not offered (they show up in the same
# list under other categories and are filtered out).
#
# A voice id outside this list that a resident already has is kept: the
# Agent validation only checks a voice id when it changes.
class ElevenLabsVoices

  class Unavailable < StandardError; end

  Voice = Data.define(:voice_id, :name, :description, :labels, :preview_url) do
    def as_json(*) = { voice_id:, name:, description:, labels:, preview_url: }
  end

  API_URL = "https://api.elevenlabs.io/v1/voices".freeze
  CACHE_KEY = "eleven_labs_voices:premade:v1".freeze
  CACHE_FOR = 12.hours
  STANDARD_CATEGORY = "premade".freeze
  OPEN_TIMEOUT = 5
  READ_TIMEOUT = 10

  # Sorted by name. Raises Unavailable when the list can't be read (no key,
  # provider down); callers decide whether that refuses or degrades.
  def self.catalogue
    rows = Rails.cache.fetch(CACHE_KEY, expires_in: CACHE_FOR, skip_nil: true) { fetch_rows }
    rows.map { |row| Voice.new(**row.symbolize_keys) }
  end

  def self.find(voice_id)
    catalogue.find { |voice| voice.voice_id == voice_id.to_s }
  end

  def self.standard?(voice_id)
    find(voice_id).present?
  end

  def self.fetch_rows
    uri = URI(API_URL)
    request = Net::HTTP::Get.new(uri)
    request["xi-api-key"] = api_key
    request["Accept"] = "application/json"
    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true,
      open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) { |http| http.request(request) }
    raise Unavailable, "ElevenLabs voice list returned #{response.code}" unless response.code.to_i == 200

    rows_from(JSON.parse(response.body))
  rescue JSON::ParserError, Net::OpenTimeout, Net::ReadTimeout, SocketError, SystemCallError, OpenSSL::SSL::SSLError => e
    raise Unavailable, "ElevenLabs voice list could not be read (#{e.class})"
  end

  def self.rows_from(payload)
    Array(payload["voices"]).filter_map do |voice|
      next unless voice["category"] == STANDARD_CATEGORY && voice["voice_id"].present?

      labels = voice["labels"].is_a?(Hash) ? voice["labels"].slice("accent", "age", "gender", "use_case", "description") : {}
      {
        voice_id: voice["voice_id"].to_s,
        name: voice["name"].to_s,
        description: (voice["description"].presence || labels["description"]).to_s,
        labels: labels.except("description"),
        preview_url: voice["preview_url"].presence
      }
    end.sort_by { |row| row[:name].downcase }
  end

  def self.api_key
    Rails.application.credentials.dig(:ai, :eleven_labs, :api_token) ||
      raise(Unavailable, "ElevenLabs API key not configured")
  end

  private_class_method :fetch_rows, :rows_from, :api_key

end
