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

  Status = Struct.new(:offered, :available, :reason, keyword_init: true) do
    def as_json(*) = { "offered" => offered, "available" => available, "reason" => reason }
  end

  def self.status_for(account)
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

end
