# Listen's stored audio, made by ElevenLabs with the account's own key, only
# while SpeechEngine still says this resident speaks through ElevenLabs (the
# account may have switched to Phonon since the request).
class GenerateVoiceJob < ApplicationJob

  queue_as :default

  retry_on ElevenLabsTts::Error, wait: 5.seconds, attempts: 3
  retry_on AudioGain::Failed, wait: 5.seconds, attempts: 2
  discard_on ActiveRecord::RecordNotFound
  # Two Listen presses on one message make one render (eOyXXJ).
  limits_concurrency to: 1, key: ->(message) { "generate-voice-#{message.id}" }, duration: 5.minutes

  # The voice and delivery are read once, here, and the audio is marked with
  # that snapshot's digest, so a change made while ElevenLabs works never
  # labels the older sound as current.
  def perform(message)
    return unless message.voice_available

    agent = message.agent
    voice_id = agent.voice_id
    delivery = agent.speech_delivery
    digest = delivery.digest(voice_id)
    return if message.voice_audio_made_with?(digest)

    account = message.chat.account
    engine = SpeechEngine.for(account, message.agent)
    return unless engine.elevenlabs? && engine.available

    text = message.content_for_speech
    return if text.blank?

    audio_data = ElevenLabsTts.synthesize(text, voice_id:, api_key: account.eleven_labs_api_key, delivery:)
    audio_data = AudioGain.apply(audio_data, delivery.gain_db, tempo: delivery.tempo)

    message.voice_audio.attach(
      io: StringIO.new(audio_data),
      filename: "voice-#{message.to_param}.mp3",
      content_type: "audio/mpeg",
      metadata: { "voice_digest" => digest }
    )
  end

end
