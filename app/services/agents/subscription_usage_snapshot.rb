# The usage figure on a resident card is a copy of the provider's own number,
# read through the resident's runtime. A fresh read costs 0.2-3 s for a
# resident in the house and about 5 s for one on its own VM (a runner command
# the web request waits on), and the cards ask every few minutes. So the last
# read is kept in the cache and served stale-while-revalidate: under FRESH_FOR
# as it is; older, up to STALE_LIMIT, at once with `stale` and `checked_at`
# so the card can say how old it is, while one background job reads it again.
# With nothing kept, or when the person asks for a refresh, the read is live.
class Agents::SubscriptionUsageSnapshot

  FRESH_FOR = 60.seconds
  STALE_LIMIT = 30.minutes
  REFRESH_LOCK_FOR = 2.minutes
  UNAVAILABLE_ALLOWANCE = { status: "unavailable", stale: nil, checked_at: nil, windows: [].freeze }.freeze

  def self.fetch(agent, refresh: false) = new(agent).fetch(refresh:)

  # For owner dashboards: neither a cold nor a stale cache can start work.
  def self.cached_allowance(agent)
    provider = Agents::Sandbox.subscription_provider_for(agent)
    return UNAVAILABLE_ALLOWANCE unless provider && agent.provider_auth_mode(provider) == "oauth_account"

    new(agent).cached_allowance
  end

  def initialize(agent)
    @agent = agent
    @provider = Agents::Sandbox.chaos_provider_for(agent)
    @model = Agents::Sandbox.chaos_model_for(agent)
  end

  def fetch(refresh: false)
    kept = refresh ? nil : read
    return live!(refresh:) unless kept

    age = Time.current.to_f - kept["fetched_at"].to_f
    return present(kept, stale: false) if age < FRESH_FOR

    enqueue_refresh
    present(kept, stale: true)
  end

  def cached_allowance
    kept = read_cached_snapshot
    return UNAVAILABLE_ALLOWANCE unless kept && kept["fetched_at"].is_a?(Numeric)

    now = Time.current
    age = now.to_f - kept["fetched_at"].to_f
    return UNAVAILABLE_ALLOWANCE unless age >= 0 && age < STALE_LIMIT

    windows = Array(kept["snapshot"]["windows"]).filter_map { |window| allowance_window(window) }
    return UNAVAILABLE_ALLOWANCE unless windows.any? { |window| !window[:remaining_percent].nil? }

    {
      status: "available",
      stale: age >= FRESH_FOR || windows.any? { |window| window[:resets_at] && Time.iso8601(window[:resets_at]) <= now },
      checked_at: Time.at(kept["fetched_at"]).utc.iso8601,
      windows:
    }
  end

  # Raises AgentProviderAuthClient::Error, as the live read always did.
  def live!(refresh: false)
    present(store(read_provider(refresh:)), stale: false)
  end

  # The background half: read again, keep it, release the refresh lock.
  def refresh!
    store(read_provider)
  rescue AgentProviderAuthClient::Error => e
    Rails.logger.info("subscription usage refresh failed agent=#{agent.id}: #{e.message}")
    nil
  ensure
    Rails.cache.delete(lock_key)
  end

  def cache_key = "provider_subscription_usage/v1/#{agent.id}/#{provider}/#{model}"

  private

  attr_reader :agent, :provider, :model

  # `refresh` asks the runtime to skip its own short cache too.
  def read_provider(refresh: false)
    AgentProviderAuthClient.new(agent).usage(provider:, model:, refresh:)
  end

  def read
    kept = read_cached_snapshot
    return nil unless kept
    return nil if Time.current.to_f - kept["fetched_at"].to_f >= STALE_LIMIT
    # A limit whose reset has passed is not a limit any more; read again.
    return nil if limit_lifted?(kept["snapshot"])

    kept
  end

  def read_cached_snapshot
    kept = Rails.cache.read(cache_key)
    kept if kept.is_a?(Hash) && kept["snapshot"].is_a?(Hash)
  end

  # Explicit allowlist, not the provider response (which can have metadata).
  def allowance_window(window)
    return unless window.is_a?(Hash) && window["id"].is_a?(String) && window["id"].present?

    remaining = window["remaining_percent"]
    remaining = nil unless remaining.is_a?(Numeric) && remaining.between?(0, 100)
    {
      id: window["id"],
      remaining_percent: remaining,
      resets_at: allowance_reset(window["resets_at"])
    }
  end

  def allowance_reset(value)
    Time.iso8601(value).utc.iso8601 if value.is_a?(String)
  rescue ArgumentError
    nil
  end

  def store(snapshot)
    kept = { "snapshot" => snapshot, "fetched_at" => Time.current.to_f }
    Rails.cache.write(cache_key, kept, expires_in: STALE_LIMIT)
    kept
  end

  def enqueue_refresh
    return unless Rails.cache.write(lock_key, true, unless_exist: true, expires_in: REFRESH_LOCK_FOR)

    RefreshSubscriptionUsageJob.perform_later(agent.id)
  end

  def lock_key = "#{cache_key}/refreshing"

  def present(kept, stale:)
    kept["snapshot"].merge(
      "stale" => stale,
      "checked_at" => Time.zone.at(kept["fetched_at"].to_f).iso8601
    )
  end

  def limit_lifted?(snapshot)
    return false unless snapshot["status"] == "limited"

    resets = Array(snapshot["windows"]).filter_map do |window|
      next unless window.is_a?(Hash) && window["blocking"]

      Time.zone.parse(window["resets_at"].to_s) if window["resets_at"].present?
    rescue ArgumentError
      nil
    end
    resets.any? && resets.max <= Time.current
  end

end
