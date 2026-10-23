class VersionVoiceEmbeddingProfiles < ActiveRecord::Migration[8.1]

  ECAPA = "ecapa-voxceleb-0f99f2d0ebe8-speechbrain-1.1.2-torch-2.14.1-v1"

  def change
    add_column :settings, :voice_embedding_profile, :string, null: false, default: ECAPA
    add_column :accounts, :voice_embedding_profile, :string, null: false, default: ECAPA
    add_column :accounts, :voice_conversion_status, :string
    add_column :accounts, :voice_conversion_error, :string
    add_column :field_voice_samples, :rollback_embedding, :text
    add_column :field_voice_samples, :rollback_profile, :string
  end

end
