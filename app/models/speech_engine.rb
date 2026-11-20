# Which engine reads a resident's messages aloud, and if it can't, why
# (jEDyze, Daniel in YgDwre enwVgQ). Phonon, running in the person's browser on
# WebGPU, is the default. ElevenLabs is an engine an account opts into, only
# where the site offers it (Setting#speech_engine_for), with the account's own
# ElevenLabs key, and only where that account is on Partners or Colleagues
# (Billing::AccountPlan; Daniel, eRyZBY 17 Nov: "Only Partners and Colleagues
# gets ElevenLabs"), whatever the resident's size.
#
# The plan checked is the plan of the account whose setting and key are used
# (the conversation's account), not the resident's home account: for a guest
# they differ, and the benefit goes with the account paying for the key
# (Mira, #1027 review). The resident's own hosting must still be in force.
#
# There is no fallback in either direction: an account on ElevenLabs without a
# key gets an error, not Phonon; a browser that can't run Phonon shows an
# error, not ElevenLabs. The house's ElevenLabs credential is never a
# fallback either. It is used only for an account a site admin has switched
# onto it (Account#house_eleven_labs_key; Daniel, YEDPGJ JBVDmo), and only
# while that account has no key of its own: the account's own key always
# comes first. The key is resolved when the audio is made, not when it is
# asked for, so switching the flag off stops queued work from starting new
# calls on the house key (Mira, JkRXoj). A resident of a
# Companions account set to ElevenLabs speaks with Phonon: that is the plan
# rule, decided before anything is tried, not a substitute after a failure.
#
# Every speech surface asks here: voice mode's streamed speech, Listen's stored
# audio, and the speech text the browser hands to Phonon.
module SpeechEngine

  PHONON = "phonon"
  ELEVENLABS = "elevenlabs"
  # Account plans whose residents may speak through ElevenLabs.
  ELEVENLABS_PLANS = %w[partners colleagues].freeze
  ACCOUNT_KEY = "account"
  HOUSE_KEY = "house"
  KEY_SOURCES = [ ACCOUNT_KEY, HOUSE_KEY ].freeze

  # value is never logged or sent anywhere but ElevenLabs.
  Key = Data.define(:value, :source) do
    def house? = source == HOUSE_KEY
    def inspect = "#<SpeechEngine::Key source=#{source}>"
    alias_method :to_s, :inspect
  end

  Status = Struct.new(:engine, :available, :reason, :key_source, keyword_init: true) do
    def phonon? = engine == PHONON
    def elevenlabs? = engine == ELEVENLABS
    def as_json(*) = { "engine" => engine, "available" => available, "reason" => reason, "message" => message }

    def message
      case reason
      when "no_eleven_labs_key"
        "This account speaks with ElevenLabs but has no ElevenLabs key of its own. Add one in the account's Voice settings, or switch the account back to Phonon."
      when "no_eleven_labs_voice"
        "This resident has no ElevenLabs voice chosen. Pick one on its Appearance tab."
      end
    end
  end

  # The account-level engine: what the site and the account ask for.
  def self.account_engine(account)
    Setting.instance.speech_engine_for(account)
  end

  def self.for(account, agent)
    engine = account_engine(account)
    engine = PHONON if engine == ELEVENLABS && !elevenlabs_plan?(account, agent)
    return Status.new(engine: PHONON, available: true, reason: nil) if engine == PHONON

    key = eleven_labs_key(account)
    return Status.new(engine:, available: false, reason: "no_eleven_labs_key") unless key
    return Status.new(engine:, available: false, reason: "no_eleven_labs_voice") if agent&.voice_id.blank?

    Status.new(engine:, available: true, reason: nil, key_source: key.source)
  end

  # The ElevenLabs key this account's speech runs on: its own, or the house's
  # when a site admin has allowed it and the account has none; otherwise nil.
  def self.eleven_labs_key(account)
    return nil if account.nil?

    own = account.eleven_labs_api_key
    return Key.new(value: own, source: ACCOUNT_KEY) if own.present?
    return nil unless account.house_eleven_labs_key?

    house = house_eleven_labs_key
    house.present? ? Key.new(value: house, source: HOUSE_KEY) : nil
  end

  def self.house_eleven_labs_key
    Rails.application.credentials.dig(:ai, :eleven_labs, :api_token).presence
  end

  # Whether this account's plan lets this resident speak through ElevenLabs
  # here: the account supplying the setting and key is on one of
  # ELEVENLABS_PLANS, and the resident's own hosting is in force (active,
  # grace or complimentary), or it has no entitlement and no birth order (on
  # the house), as for sub-agents (Agent::Subagents).
  def self.elevenlabs_plan?(account, agent)
    return false if account.nil? || agent.nil?
    return false unless account.plan&.id.in?(ELEVENLABS_PLANS)

    entitlement = ResidentEntitlement.find_by(agent_id: agent.id)
    return !ResidentBirthOrder.exists?(agent_id: agent.id) if entitlement.nil?
    return true if entitlement.complimentary? || entitlement.complimentary_granted_at.present?

    entitlement.state.in?(Billing::Tier::IN_FORCE_STATES)
  end

  # Whether the site lets accounts pick ElevenLabs at all (the account setting
  # offers the choice only then).
  def self.choice_offered?
    Setting.instance.speech_engine_scope == "account_choice"
  end

  # The resident's Phonon voice id: its own choice, or the catalogue default.
  def self.phonon_voice_for(agent)
    PhononVoices.find(agent&.phonon_voice)&.id || PhononVoices.default.id
  end

end
