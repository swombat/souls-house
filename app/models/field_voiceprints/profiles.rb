# The service contract and matching recipe are one versioned choice. Selecting
# an engine is explicit; a new sample can never select it for the account.
module FieldVoiceprints::Profiles

  ECAPA = "ecapa-voxceleb-0f99f2d0ebe8-speechbrain-1.1.2-torch-2.14.1-v1"
  WESPEAKER = "wespeaker-voxceleb-837717ddb9ff-pyannote-4.0.7-torch-2.14.1-whole-v1"

  RECIPES = {
    ECAPA => { dimensions: 192, engine: "ecapa", threshold: 0.55, margin: 0.15, split: 0.75 },
    # Development-only pair translation with explicit conservative floors.
    # See docs/research/wespeaker-policy-calibration.md; not a safety guarantee.
    WESPEAKER => { dimensions: 256, engine: "wespeaker", threshold: 0.55, margin: 0.15, split: 0.764 }
  }.transform_values(&:freeze).freeze

  module_function

  def configured = Setting.instance.voice_embedding_profile
  def active(account) = account.voice_embedding_profile
  def recipe(profile) = RECIPES.fetch(profile)

  def valid_vector?(vector, profile)
    definition = RECIPES[profile]
    definition && vector.is_a?(Array) && vector.size == definition[:dimensions] &&
      vector.all? { |value| value.is_a?(Numeric) && value.finite? && value.abs <= 1_000 } &&
      vector.any? { |value| value != 0 }
  end

end
