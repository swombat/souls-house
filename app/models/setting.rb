class Setting < ApplicationRecord

  include Broadcastable
  include RetainsReplacedAttachment

  FOLLOW_THROUGH_SCOPES = %w[off selected all].freeze
  REFLEXES_SCOPES = %w[disabled account_choice enabled].freeze
  VOICE_MODE_SCOPES = %w[disabled account_choice enabled].freeze
  SPEECH_ENGINE_SCOPES = %w[disabled account_choice enabled].freeze
  TWEET_STREAM_COLUMNS = %w[
    field_tweets_enabled field_tweets_daily_import_cap
    field_tweets_account_monthly_usd_ceiling field_tweets_poll_minutes
    field_tweets_house_halted_at
  ].freeze

  has_one_attached :logo
  # Removed and replaced logos keep their bytes, hidden (#93).
  retains_replaced_attachment :logo, history: :retired_logos

  # Field OCR covers only files brought in after it was (last) turned on.
  before_save { self.field_ocr_enabled_at = Time.current if field_ocr_enabled_changed?(to: true) }
  # When billing was (last) switched on: accounts created since then pay.
  before_save { self.billing_enabled_at = Time.current if billing_enabled_changed?(to: true) }
  after_save :refresh_tweet_streams, if: :tweet_stream_changed?
  after_save :refresh_glossaries, if: :saved_change_to_site_name?
  after_save :invalidate_voice_mode, if: :voice_scope_changed?

  validates :max_accounts, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :voice_embedding_profile, inclusion: { in: FieldVoiceprints::Profiles::RECIPES.keys }
  validates :resident_turn_limit, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 1_000 }
  validates :field_ocr_daily_usd_ceiling, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }
  validates :field_tweets_site_monthly_usd_ceiling, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1_000 }
  validates :field_tweets_account_monthly_usd_ceiling, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }
  validates :field_tweets_daily_import_cap, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 1_000 }
  validates :field_tweets_poll_minutes, numericality: { only_integer: true, greater_than_or_equal_to: 5, less_than_or_equal_to: 1_440 }
  validates :vm_resident_limit, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 1_000 }
  validates :follow_through_scope, inclusion: { in: FOLLOW_THROUGH_SCOPES }
  validates :reflexes_scope, inclusion: { in: REFLEXES_SCOPES }
  validates :voice_mode_scope, inclusion: { in: VOICE_MODE_SCOPES }
  validates :speech_engine_scope, inclusion: { in: SPEECH_ENGINE_SCOPES }
  validates :stalled_sweep_minutes, inclusion: { in: StalledThreadSweeper::INTERVALS }
  validates :site_name, presence: true, length: { maximum: 100 }
  # The Mac main download stays blank until a Developer ID-signed, notarised build
  # exists; https only. Each other download offered with a checksum beside it: address + sha256, both or neither.
  COMPANION_CHECKSUMMED_DOWNLOADS = %i[companion_mac_early companion_linux_amd64 companion_linux_arm64].freeze
  COMPANION_DOWNLOAD_URLS = [ :companion_mac_download_url, *COMPANION_CHECKSUMMED_DOWNLOADS.map { |d| :"#{d}_download_url" } ].freeze
  COMPANION_DOWNLOAD_SHAS = COMPANION_CHECKSUMMED_DOWNLOADS.map { |d| :"#{d}_download_sha256" }.freeze
  normalizes(*COMPANION_DOWNLOAD_URLS, with: ->(url) { url.strip.presence })
  normalizes(*COMPANION_DOWNLOAD_SHAS, with: ->(sum) { sum.strip.downcase.presence })
  validates(*COMPANION_DOWNLOAD_URLS, length: { maximum: 500 },
    format: { with: %r{\Ahttps://[^\s]+\z}, message: "must be an https:// address" }, allow_nil: true)
  validates(*COMPANION_DOWNLOAD_SHAS, format: { with: /\A\h{64}\z/, message: "must be 64 hex characters" },
    allow_nil: true)
  validate :companion_early_download_pair
  validates :safeguard_owner_notice_threshold,
    numericality: { only_integer: true, greater_than_or_equal_to: 1 }
  validates :logo, content_type: [ :png, :jpg, :gif, :webp, :svg ],
                   size: { less_than: 5.megabytes },
                   if: -> { logo.attached? }

  broadcasts_to :all

  def account_creation_allowed?(user = Current.user)
    user&.is_site_admin? || Account.uncached { Account.count } < max_accounts
  end

  # Follow-through checks (FollowThroughCheck) are opt-in: off, on for the
  # residents an admin has picked (agents.follow_through), or on for all.
  def follow_through_enabled_for?(agent)
    return false if agent.nil?
    case follow_through_scope
    when "all" then true
    when "selected" then agent.follow_through?
    else false
    end
  end

  # Reflex checks (ReflexCheck) run where the site scope says (#520):
  # disabled is off everywhere and enabled is on everywhere, whatever an
  # account says; under account_choice the resident's account switch
  # (accounts.reflexes_enabled) decides.
  def reflexes_enabled_for?(agent)
    return false if agent.nil?
    case reflexes_scope
    when "enabled" then true
    when "account_choice" then agent.account&.reflexes_enabled? || false
    else false
    end
  end

  # Voice mode in conversations (VoiceMode) follows the same three states:
  # disabled is off for every account, enabled is on for every account, and
  # under account_choice (the default) the account's own switch
  # (accounts.voice_mode_enabled) decides. An account's switch is kept while
  # the site overrides it.
  def voice_mode_enabled_for?(account)
    return false if account.nil?
    case voice_mode_scope
    when "enabled" then true
    when "account_choice" then account.voice_mode_enabled? || false
    else false
    end
  end

  # The ElevenLabs option for resident speech (SpeechEngine), in the same three
  # states: disabled (the default) is Phonon for every account, enabled is
  # ElevenLabs for every account, and under account_choice the account's own
  # choice (accounts.speech_engine) decides. Returns the engine the site asks
  # for; SpeechEngine then checks the key and the resident's plan.
  def speech_engine_for(account)
    case speech_engine_scope
    when "enabled" then "elevenlabs"
    when "account_choice" then account&.speech_engine.presence || "phonon"
    else "phonon"
    end
  end

  def self.instance
    first_or_create!(site_name: ENV.fetch("SOULSHOUSE_SITE_NAME", "souls.house"))
  end

  # The feature flags StarGates resolves: the admin switches, as flags.
  def self.feature_flags
    instance = self.instance
    {
      agents: instance.allow_agents,
      chats: instance.allow_chats,
      signups: instance.allow_signups
    }
  end

  def self.feature_enabled?(flag)
    StarGates.flags.enabled?(flag)
  end

  private

  def refresh_glossaries
    self.class.current_transaction.after_commit { RefreshGlossarySettingsJob.perform_later }
  end

  def tweet_stream_changed?
    return true if (saved_changes.keys & TWEET_STREAM_COLUMNS).any?

    if saved_change_to_field_tweets_site_monthly_usd_ceiling?
      saved_change_to_field_tweets_site_monthly_usd_ceiling.map { |value| value.to_d.positive? }.uniq.size > 1
    end
  end

  def refresh_tweet_streams
    self.class.current_transaction.after_commit { FieldTweets::RefreshSettingsJob.perform_later }
  end

  def voice_scope_changed?
    saved_change_to_speech_engine_scope? || saved_change_to_voice_mode_scope?
  end

  def invalidate_voice_mode
    self.class.current_transaction.after_commit { VoiceModeInvalidationJob.perform_later }
  end

  def companion_early_download_pair
    COMPANION_CHECKSUMMED_DOWNLOADS.each do |download|
      next if self[:"#{download}_download_url"].nil? == self[:"#{download}_download_sha256"].nil?

      errors.add(:"#{download}_download_sha256", "and its download address go together")
    end
  end

end
