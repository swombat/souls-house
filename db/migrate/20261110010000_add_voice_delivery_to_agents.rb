class AddVoiceDeliveryToAgents < ActiveRecord::Migration[8.1]

  # How a resident's ElevenLabs voice is read aloud (eOyXXJ): model, speed,
  # stability, similarity, style, speaker boost and a gain applied afterwards.
  # Nil means the house defaults, exactly as before this column existed.
  def change
    add_column :agents, :voice_delivery, :jsonb
  end

end
