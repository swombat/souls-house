# The ElevenLabs voices a resident may speak with.
#
# The standard set (catalogue) is the provider's premade voices, read from
# GET /v1/voices with the house's key and cached for every account.
#
# An account with its own ElevenLabs key also gets its own library
# (library): the cloned, generated and professional voices in that
# ElevenLabs account, read with that account's key. These were once
# deliberately not offered, because they would have spoken on the house's key
# and credit. Speech now runs on the account's own key (SpeechEngine), so a
# voice the account made or added is the account's choice to use, and nobody
# else's account ever sees it: the list is cached per account and per key.
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
  LIBRARY_CACHE_KEY = "eleven_labs_voices:library:v1".freeze
  LIBRARY_CACHE_FOR = 10.minutes
  STANDARD_CATEGORY = "premade".freeze
  OPEN_TIMEOUT = 5
  READ_TIMEOUT = 10

  # Sorted by name. Raises Unavailable when the list can't be read (no key,
  # provider down); callers decide whether that refuses or degrades.
  def self.catalogue
    rows = Rails.cache.fetch(CACHE_KEY, expires_in: CACHE_FOR, skip_nil: true) { fetch_rows(api_key, standard: true) }
    rows.map { |row| Voice.new(**row.symbolize_keys) }
  end

  # The account's own voices (everything in its ElevenLabs library that isn't
  # premade), sorted by name; [] when the account has no key of its own.
  # Raises Unavailable when the account's list can't be read. The cache key
  # carries a digest of the key, never the key, so a changed key reads afresh.
  def self.library(account)
    key = account&.eleven_labs_api_key
    return [] if key.blank?

    cache_key = "#{LIBRARY_CACHE_KEY}:#{account.id}:#{Digest::SHA256.hexdigest(key)[0, 16]}"
    rows = Rails.cache.fetch(cache_key, expires_in: LIBRARY_CACHE_FOR, skip_nil: true) { fetch_rows(key, standard: false) }
    rows.map { |row| Voice.new(**row.symbolize_keys) }
  end

  def self.find_in_library(account, voice_id)
    library(account).find { |voice| voice.voice_id == voice_id.to_s }
  end

  # Whether this account's resident may be given this voice: a standard one,
  # or one from the account's own library. Raises Unavailable only when
  # neither list could say yes and one of them couldn't be read.
  def self.offerable?(account, voice_id)
    unreadable = nil
    begin
      return true if standard?(voice_id)
    rescue Unavailable => e
      unreadable = e
    end
    return true if find_in_library(account, voice_id)
    raise unreadable if unreadable

    false
  end

  def self.find(voice_id)
    catalogue.find { |voice| voice.voice_id == voice_id.to_s }
  end

  def self.standard?(voice_id)
    find(voice_id).present?
  end

  def self.fetch_rows(key, standard:)
    uri = URI(API_URL)
    request = Net::HTTP::Get.new(uri)
    request["xi-api-key"] = key
    request["Accept"] = "application/json"
    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true,
      open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) { |http| http.request(request) }
    raise Unavailable, "ElevenLabs voice list returned #{response.code}" unless response.code.to_i == 200

    rows_from(JSON.parse(response.body), standard:)
  rescue JSON::ParserError, Net::OpenTimeout, Net::ReadTimeout, SocketError, SystemCallError, OpenSSL::SSL::SSLError => e
    raise Unavailable, "ElevenLabs voice list could not be read (#{e.class})"
  end

  def self.rows_from(payload, standard: true)
    Array(payload["voices"]).filter_map do |voice|
      next if voice["voice_id"].blank?
      next unless (voice["category"] == STANDARD_CATEGORY) == standard

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
