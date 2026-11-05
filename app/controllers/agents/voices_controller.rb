# A resident's speaking voice, chosen by a person on the Appearance tab: one
# of the standard ElevenLabs voices (ElevenLabsVoices), or none. Saved
# straight away, like the picture, so the tab's other fields aren't
# submitted with it. The resident can choose for itself through
# PATCH /api/v1/agent/voice; whichever change comes last stands, and both
# are audited.
class Agents::VoicesController < ApplicationController

  require_feature_enabled :agents
  before_action :set_agent

  PREVIEW_CACHE_FOR = 7.days

  # The standard voices for the picker, fetched by the page after it draws.
  def index
    render json: { current_voice_id: @agent.voice_id, voices: ElevenLabsVoices.catalogue.map(&:as_json) }
  rescue ElevenLabsVoices::Unavailable
    render json: { current_voice_id: @agent.voice_id, voices: [], unavailable: true }
  end

  # voice_id sets the ElevenLabs voice; phonon_voice the Phonon one (nil for
  # the catalogue default). Each engine keeps its own choice (SpeechEngine).
  def update
    return update_phonon_voice if params.key?(:phonon_voice)

    @agent.voice_id = params[:voice_id]
    if @agent.save
      audit(:set_agent_voice, @agent, voice_id: @agent.voice_id)
      respond_ok(@agent.voice_id ? "Voice updated" : "Voice removed")
    else
      respond_error(@agent.errors.full_messages_for(:voice_id).to_sentence.presence || @agent.errors.full_messages.to_sentence)
    end
  end

  def update_phonon_voice
    @agent.phonon_voice = params[:phonon_voice]
    if @agent.save
      audit(:set_agent_voice, @agent, phonon_voice: @agent.phonon_voice)
      respond_ok("Voice updated", :phonon_voice)
    else
      respond_error(@agent.errors.full_messages_for(:phonon_voice).to_sentence.presence || @agent.errors.full_messages.to_sentence,
        :phonon_voice)
    end
  end

  # The resident saying one line in the given voice, rendered through the
  # same ElevenLabsTts call its messages use, so what you hear is what its
  # messages will sound like. Standard voices only; cached per voice and name.
  def preview
    voice = ElevenLabsVoices.find(params[:voice_id])
    return head(:not_found) unless voice

    text = self.class.preview_text(@agent.name)
    key = "agent_voice_preview:#{voice.voice_id}:#{ElevenLabsTts::MODEL_ID}:#{Digest::SHA256.hexdigest(text)}"
    audio = Rails.cache.fetch(key, expires_in: PREVIEW_CACHE_FOR) { ElevenLabsTts.synthesize(text, voice_id: voice.voice_id) }
    send_data audio, type: "audio/mpeg", disposition: "inline", filename: "voice-preview.mp3"
  rescue ElevenLabsVoices::Unavailable, ElevenLabsTts::Error => e
    render plain: e.message, status: :service_unavailable
  end

  def self.preview_text(name)
    "Hello, I'm #{name.to_s.squish.truncate(60)}. This is how I'll sound when you play my messages aloud."
  end

  private

  def set_agent
    @agent = current_account.agents.find(params[:id])
  end

  def back_path
    edit_account_agent_path(current_account, @agent, tab: "appearance")
  end

  def respond_ok(notice, field = :voice_id)
    inertia_request? ?
      redirect_with_inertia_flash(:success, notice, back_path) :
      render(json: { success: true, field => @agent.public_send(field) }, status: :ok)
  end

  def respond_error(message, field = :voice_id)
    inertia_request? ?
      redirect_to(back_path, inertia: { errors: { field => message } }) :
      render(json: { errors: [ message ] }, status: :unprocessable_entity)
  end

  def inertia_request?
    request.headers["X-Inertia"].present?
  end

end
