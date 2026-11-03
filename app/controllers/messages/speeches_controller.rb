# Voice mode (YMaddY, PR 2): a resident message read aloud in its own voice,
# streamed from ElevenLabs as it is made so the browser can start playing at
# the first chunk. Asked for only by a browser in voice mode; nothing is stored.
class Messages::SpeechesController < Messages::BaseController

  include ActionController::Live

  def show
    return head(:forbidden) unless VoiceMode.status_for(@chat.account).offered
    return head(:unprocessable_entity) unless @message.voice_available

    text = VoiceMode.speech_text(@message, from_seconds: resume_seconds)
    return head(:no_content) if text.blank?

    response.headers["Content-Type"] = "audio/mpeg"
    response.headers["Cache-Control"] = "no-store"
    response.headers["Last-Modified"] = Time.current.httpdate # bypass Rack::ETag buffering
    response.headers["X-Accel-Buffering"] = "no"
    started = false
    ElevenLabsTts.stream(text, voice_id: @message.agent.voice_id) do |chunk|
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

  private

  # ?from=<seconds> when a reply comes back after being spoken over (#758).
  def resume_seconds
    seconds = Float(params[:from], exception: false)
    seconds.clamp(0, 3600) if seconds&.finite?
  end

end
