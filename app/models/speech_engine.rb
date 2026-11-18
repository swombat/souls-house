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
# key gets an error, not Phonon, and not the house's ElevenLabs credential; a
# browser that can't run Phonon shows an error, not ElevenLabs. A resident of a
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

  Status = Struct.new(:engine, :available, :reason, keyword_init: true) do
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

    return Status.new(engine:, available: false, reason: "no_eleven_labs_key") if account&.eleven_labs_api_key.blank?
    return Status.new(engine:, available: false, reason: "no_eleven_labs_voice") if agent&.voice_id.blank?

    Status.new(engine:, available: true, reason: nil)
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
