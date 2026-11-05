# Whether a person can open voice mode in an account's conversations, and if
# not, why. Two gates, both answered here so the server and the composer agree:
#
# 1. The site scope and the account switch (Setting#voice_mode_enabled_for?).
#    When they say no, the wave button is not shown at all (`offered` false).
# 2. A transcription key. The account's own OpenAI key, or the house's when the
#    account falls through to house credentials (Account#ai_api_key honours
#    use_system_ai_credentials). Without one the button is shown but cannot be
#    pressed, and the tooltip says what is missing (Daniel, YgDwre JAbodj).
#
# Messages::PostFromHuman asks the same question before it marks a message as
# spoken in the mode, so hiding the button is never the only enforcement.
module VoiceMode

  TRANSCRIPTION_PROVIDER = :openai

  # speech_engine: the account's voice engine (SpeechEngine), so an open
  # voice-mode panel can stop reading when it changes.
  Status = Struct.new(:offered, :available, :reason, :speech_engine, keyword_init: true) do
    def as_json(*) = { "offered" => offered, "available" => available, "reason" => reason, "speech_engine" => speech_engine }
  end

  def self.status_for(account)
    status = gated_status(account)
    status.speech_engine = SpeechEngine.account_engine(account) if account
    status
  end

  def self.gated_status(account)
    return Status.new(offered: false, available: false, reason: "site_disabled") if account.nil?

    setting = Setting.instance
    unless setting.voice_mode_enabled_for?(account)
      reason = setting.voice_mode_scope == "disabled" ? "site_disabled" : "account_disabled"
      return Status.new(offered: false, available: false, reason:)
    end
    return Status.new(offered: true, available: false, reason: "no_transcription_key") unless transcription_key?(account)

    Status.new(offered: true, available: true, reason: nil)
  end

  def self.available_for?(account)
    status_for(account).available
  end

  def self.transcription_key?(account)
    ResolvesProvider.api_key_available?(TRANSCRIPTION_PROVIDER, account:)
  end

  # What is read aloud for a resident message in voice mode. A long reply is
  # cut at the last sentence end before the cap and says so, so the person on
  # a walk knows there is more on screen rather than hearing it stop.
  SPEECH_CAP = 900
  SPEECH_TRUNCATION_NOTE = "The rest is on screen."

  # Who a spoken turn is for, in a room where an untagged message wakes nobody
  # (manual responses). Nobody says "@Mira" aloud, so, in order:
  #
  # 1. A turn that opens with a resident's name is for that resident ("Mira,
  #    what do you think").
  # 2. A short turn that names exactly one resident anywhere is for them ("So
  #    now I'm going to say, hey Lume, what's up?", #747).
  # 3. Otherwise it continues with whoever spoke last here.
  # 4. In a chat no resident has answered yet there is no one to continue
  #    with: the one resident named anywhere in the turn, however long, and
  #    with no name, the first resident listed on the chat (#747: "Hey Lume"
  #    in a fresh chat woke nobody).
  #
  # A name two residents share picks nobody, as a shared tag does; two
  # different names in a fresh chat pick nobody rather than guess. nil when no
  # one fits.
  LEADING_FILLER = /\A[\s"“'‘(]*(?:(?:hey|hi|ok|okay|so|and|right)[\s,]+)?/i
  SHORT_TURN_WORDS = 25

  def self.addressee(chat, content)
    return nil unless chat.manual_responses?

    eligible = chat.agents.reorder("chat_agents.id").select(&:eligible_for_conversation?)
    return nil if eligible.empty?

    text = content.to_s
    opening = text.sub(LEADING_FILLER, "")
    named = eligible.select { |agent| opening.match?(/\A#{name_pattern(agent)}/i) }
    return named.first if named.size == 1
    return nil if named.any?

    mentioned = eligible.select { |agent| text.match?(/(?<![[:alnum:]])#{name_pattern(agent)}/i) }
    last_id = chat.messages.kept.where(role: "assistant").where.not(agent_id: nil).reorder(id: :desc).pick(:agent_id)
    if last_id.nil?
      return mentioned.first if mentioned.size == 1
      return nil if mentioned.any?
      return eligible.first
    end

    return mentioned.first if mentioned.size == 1 && text.split.size <= SHORT_TURN_WORDS

    eligible.find { |agent| agent.id == last_id }
  end

  def self.name_pattern(agent)
    "#{Regexp.escape(agent.name)}(?![[:alnum:]])"
  end
  private_class_method :name_pattern

  def self.speech_text(message)
    text = message.content_for_speech
    return text if text.length <= SPEECH_CAP

    head = text[0, SPEECH_CAP]
    cut = head.rindex(/[.!?](\s|\z)/)
    head = cut && cut > SPEECH_CAP / 3 ? head[0..cut] : "#{head[/\A.*\s/m]&.rstrip || head}…"
    "#{head} #{SPEECH_TRUNCATION_NOTE}"
  end

end
