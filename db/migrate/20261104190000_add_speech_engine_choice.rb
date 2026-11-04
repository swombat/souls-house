# Phonon becomes the default voice for resident speech; ElevenLabs is an
# opt-in engine the site can offer (jEDyze). The site scope decides whether
# accounts may choose ElevenLabs (disabled = Phonon everywhere), the account
# keeps its choice and its own ElevenLabs key, and each resident keeps a voice
# per engine (voice_id stays the ElevenLabs one).
class AddSpeechEngineChoice < ActiveRecord::Migration[8.1]

  def change
    add_column :settings, :speech_engine_scope, :string, null: false, default: "disabled"
    add_column :accounts, :speech_engine, :string, null: false, default: "phonon"
    add_column :accounts, :eleven_labs_api_key, :text
    add_column :agents, :phonon_voice, :string
  end

end
