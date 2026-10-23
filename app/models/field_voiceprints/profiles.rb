# The service contract and matching recipe are one versioned choice. Selecting
# an engine is explicit; a new sample can never select it for the account.
#
# Each recipe has two lines. At `threshold`/`margin` a probe gets a guess (a
# chip a person confirms). At `name_threshold`/`name_margin`, and only from a
# print that passed its held-out check, the match is clear enough to name the
# speaker without a tap (Daniel, 2026-10-23, MYnpDj). The ECAPA naming line
# comes from the Grove held-out set that morning (313 queries, 17 validated
# prints): every stranger scored ≤ 0.44, every right person ≥ 0.49 with a lead
# ≥ 0.16, and 141 of 152 right answers cleared 0.70/0.20. WeSpeaker carries
# the same numbers as a conservative start (its development impostor maximum
# was 0.504); field:voiceprint_report shows what either line would do.
module FieldVoiceprints::Profiles

  ECAPA = "ecapa-voxceleb-0f99f2d0ebe8-speechbrain-1.1.2-torch-2.14.1-v1"
  WESPEAKER = "wespeaker-voxceleb-837717ddb9ff-pyannote-4.0.7-torch-2.14.1-whole-v1"

  RECIPES = {
    ECAPA => { dimensions: 192, engine: "ecapa", threshold: 0.55, margin: 0.15, split: 0.75,
               name_threshold: 0.70, name_margin: 0.20 },
    # Development-only pair translation with explicit conservative floors.
    # See docs/research/wespeaker-policy-calibration.md; not a safety guarantee.
    WESPEAKER => { dimensions: 256, engine: "wespeaker", threshold: 0.55, margin: 0.15, split: 0.764,
                   name_threshold: 0.70, name_margin: 0.20 }
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
