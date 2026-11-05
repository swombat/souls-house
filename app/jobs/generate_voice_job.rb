# Listen's stored audio, made by ElevenLabs with the account's own key, only
# while SpeechEngine still says this resident speaks through ElevenLabs (the
# account may have switched to Phonon since the request).
class GenerateVoiceJob < ApplicationJob

  queue_as :default

  retry_on ElevenLabsTts::Error, wait: 5.seconds, attempts: 3
  discard_on ActiveRecord::RecordNotFound

  def perform(message)
    return if message.voice_audio.attached?
    return unless message.voice_available

    account = message.chat.account
    engine = SpeechEngine.for(account, message.agent)
    return unless engine.elevenlabs? && engine.available

    text = message.content_for_speech
    return if text.blank?

    audio_data = ElevenLabsTts.synthesize(text, voice_id: message.agent.voice_id, api_key: account.eleven_labs_api_key)

    message.voice_audio.attach(
      io: StringIO.new(audio_data),
      filename: "voice-#{message.to_param}.mp3",
      content_type: "audio/mpeg"
    )
  end

end
