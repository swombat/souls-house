# Listen on a resident message. Under ElevenLabs (SpeechEngine) the audio is
# made once with the account's own key and stored on the message. Under Phonon
# the browser makes it from Messages::SpeechTextsController, so this refuses
# with the engine, rather than spending an ElevenLabs credit nobody chose.
class Messages::VoicesController < Messages::BaseController

  def create
    unless @message.voice_available
      render json: { error: "Voice not available for this message" }, status: :unprocessable_entity
      return
    end

    engine = SpeechEngine.for(@chat.account, @message.agent)
    unless engine.elevenlabs?
      render json: engine.as_json, status: :conflict
      return
    end
    unless engine.available
      render json: engine.as_json.merge("error" => engine.message), status: :unprocessable_entity
      return
    end

    if @message.voice_audio_current?
      render json: { voice_audio_url: @message.voice_audio_url }
    else
      GenerateVoiceJob.perform_later(@message)
      head :accepted
    end
  end

end
