# Voice mode (YMaddY, PR 2): a resident message read aloud in its own voice,
# streamed from ElevenLabs as it is made so the browser can start playing at
# the first chunk. Asked for only by a browser in voice mode; nothing is stored.
#
# Only when SpeechEngine says this resident speaks through ElevenLabs, and then
# on the key it resolves: the account's own (jEDyze), or the house's where a
# site admin allows it. Under Phonon the browser makes the audio itself from
# Messages::SpeechTextsController and never asks here.
class Messages::SpeechesController < Messages::BaseController

  include ActionController::Live

  def show
    return head(:forbidden) unless VoiceMode.status_for(@chat.account).offered
    return head(:unprocessable_entity) unless @message.voice_available

    engine = SpeechEngine.for(@chat.account, @message.agent)
    return head(:conflict) unless engine.elevenlabs?
    return render(json: engine.as_json, status: :unprocessable_entity) unless engine.available

    text = VoiceMode.speech_text(@message)
    return head(:no_content) if text.blank?

    key = SpeechEngine.eleven_labs_key(@chat.account)
    return render(json: engine.as_json, status: :unprocessable_entity) unless key

    response.headers["Content-Type"] = "audio/mpeg"
    response.headers["Cache-Control"] = "no-store"
    response.headers["Last-Modified"] = Time.current.httpdate # bypass Rack::ETag buffering
    response.headers["X-Accel-Buffering"] = "no"
    started = false
    # Delivery's model and settings apply here too; its gain does not (Listen
    # only: a gain stage would delay the first chunk or reroute the player).
    agent = @message.agent
    ElevenLabsTts.stream(text, voice_id: agent.voice_id, api_key: key.value,
      delivery: agent.speech_delivery) do |chunk|
      # Counted at the first chunk: the provider accepted it.
      SpeechCharge.record!(key:, account: @chat.account, agent:, message: @message, surface: "voice_mode", text:) unless started
      started = true
      response.stream.write(chunk)
    end
  rescue ElevenLabsTts::Error => e
    Rails.logger.warn("voice mode speech failed for message #{@message&.id}: #{e.message}")
    response.status = :bad_gateway unless started
  rescue ActionController::Live::ClientDisconnected, IOError
    # The person interrupted or ended voice mode; stop asking ElevenLabs.
  ensure
    response.stream.close
  end

end
