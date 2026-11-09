# A resident's speaking voice, chosen by a person on the Appearance tab: one
# of the standard ElevenLabs voices, one from the account's own ElevenLabs
# library when it has a key of its own (ElevenLabsVoices), or none. Saved
# straight away, like the picture, so the tab's other fields aren't
# submitted with it. The resident can choose for itself through
# PATCH /api/v1/agent/voice; whichever change comes last stands, and both
# are audited.
class Agents::VoicesController < ApplicationController

  require_feature_enabled :agents
  before_action :set_agent

  PREVIEW_CACHE_FOR = 7.days

  # The voices for the picker, fetched by the page after it draws: the
  # standard ones, and the account's own as a separate group. Either list can
  # be unreadable without hiding the other.
  def index
    body = { current_voice_id: @agent.voice_id }
    begin
      body[:voices] = ElevenLabsVoices.catalogue.map(&:as_json)
    rescue ElevenLabsVoices::Unavailable
      body[:voices] = []
      body[:unavailable] = true
    end
    begin
      body[:library_voices] = ElevenLabsVoices.library(current_account).map(&:as_json)
    rescue ElevenLabsVoices::Unavailable
      body[:library_voices] = []
      body[:library_unavailable] = true
    end
    render json: body
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
  # messages will sound like. A standard voice renders on the house's key and
  # is cached per voice and name; a voice from the account's own library
  # renders on the account's key (the house's can't see it) and its cache is
  # the account's alone.
  def preview
    voice, api_key = preview_voice(params[:voice_id])
    return head(:not_found) unless voice

    text = self.class.preview_text(@agent.name)
    scope = api_key ? "account-#{current_account.id}" : "house"
    key = "agent_voice_preview:#{scope}:#{voice.voice_id}:#{ElevenLabsTts::MODEL_ID}:#{Digest::SHA256.hexdigest(text)}"
    audio = Rails.cache.fetch(key, expires_in: PREVIEW_CACHE_FOR) do
      ElevenLabsTts.synthesize(text, voice_id: voice.voice_id, api_key:)
    end
    send_data audio, type: "audio/mpeg", disposition: "inline", filename: "voice-preview.mp3"
  rescue ElevenLabsVoices::Unavailable, ElevenLabsTts::Error => e
    render plain: e.message, status: :service_unavailable
  end

  def self.preview_text(name)
    "Hello, I'm #{name.to_s.squish.truncate(60)}. This is how I'll sound when you play my messages aloud."
  end

  private

  # The voice to preview and the key to render it on (nil: the house's).
  # As in ElevenLabsVoices.offerable?, an unreadable standard list is only
  # an answer once the account's own library has also said no: then it is
  # raised (503), not reported as an unknown voice (404).
  def preview_voice(voice_id)
    unreadable = nil
    begin
      standard = ElevenLabsVoices.find(voice_id)
      return [ standard, nil ] if standard
    rescue ElevenLabsVoices::Unavailable => e
      unreadable = e
    end

    own = ElevenLabsVoices.find_in_library(current_account, voice_id)
    return [ own, current_account.eleven_labs_api_key ] if own
    raise unreadable if unreadable

    [ nil, nil ]
  end

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
