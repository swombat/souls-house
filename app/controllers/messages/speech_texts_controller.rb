# What the browser needs to read a resident message aloud with Phonon
# (jEDyze): the engine SpeechEngine decides for this resident, the text from
# the shared speech formatter, with numbers written out, and the resident's
# Phonon voice. `for=voice_mode` gives voice mode's capped text (VoiceMode),
# anything else Listen's whole text.
#
# Under ElevenLabs this answers with the engine and no text: the browser then
# uses the streamed speech (voice mode) or the stored audio (Listen), so a
# person never gets Phonon in an ElevenLabs account by accident, nor the
# reverse. An unavailable engine comes with the reason to show.
class Messages::SpeechTextsController < Messages::BaseController

  def show
    voice_mode = params[:for] == "voice_mode"
    return head(:forbidden) if voice_mode && !VoiceMode.status_for(@chat.account).offered
    return head(:unprocessable_entity) unless @message.voice_available

    engine = SpeechEngine.for(@chat.account, @message.agent)
    body = engine.as_json
    if engine.phonon?
      text = voice_mode ? VoiceMode.speech_text(@message) : @message.content_for_speech
      body.merge!("text" => SpeechNumbers.spell(text), "voice" => SpeechEngine.phonon_voice_for(@message.agent))
    end
    response.headers["Cache-Control"] = "no-store"
    render json: body
  end

end
