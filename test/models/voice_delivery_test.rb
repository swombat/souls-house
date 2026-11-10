require "test_helper"

# A resident's ElevenLabs delivery (eOyXXJ): what is accepted, what each
# field falls back to, and the digest that marks stored Listen audio.
class VoiceDeliveryTest < ActiveSupport::TestCase

  JANIS_TAKE_03 = {
    "model_id" => "eleven_multilingual_v2", "speed" => 0.75, "stability" => 0.75,
    "similarity_boost" => 0.85, "style" => 0.15, "use_speaker_boost" => true, "gain_db" => 10
  }.freeze

  def errors_for(input)
    VoiceDelivery.normalize!(input)
    flunk "expected #{input.inspect} to be refused"
  rescue VoiceDelivery::Invalid => e
    e.errors
  end

  test "nil and an empty object are the house defaults, exactly as before" do
    assert_nil VoiceDelivery.normalize!(nil)
    assert_nil VoiceDelivery.normalize!({})

    delivery = VoiceDelivery.for(nil)
    assert_equal "eleven_v3", delivery.model_id
    assert_equal({ stability: 0.5, similarity_boost: 0.75, style: 0.0, use_speaker_boost: true, speed: 1.0 }, delivery.voice_settings)
    assert_not delivery.gain?
    assert delivery.default?
  end

  test "Janis's take 03 is kept as given, numbers as floats" do
    stored = VoiceDelivery.normalize!(JANIS_TAKE_03)
    assert_equal 10.0, stored["gain_db"]

    delivery = VoiceDelivery.for(stored)
    assert_equal "eleven_multilingual_v2", delivery.model_id
    assert_equal({ stability: 0.75, similarity_boost: 0.85, style: 0.15, use_speaker_boost: true, speed: 0.75 }, delivery.voice_settings)
    assert_equal 10.0, delivery.gain_db
    assert_equal "eleven_multilingual_v2 · speed 0.75 · stability 0.75 · similarity 0.85 · style 0.15 · +10 dB on Listen",
      delivery.summary
  end

  test "a field left out falls back to its default, and an explicit false is kept" do
    delivery = VoiceDelivery.for(VoiceDelivery.normalize!("speed" => 0.8, "use_speaker_boost" => false))
    assert_equal "eleven_v3", delivery.model_id
    assert_equal({ stability: 0.5, similarity_boost: 0.75, style: 0.0, use_speaker_boost: false, speed: 0.8 }, delivery.voice_settings)
    assert_includes delivery.summary, "speaker boost off"
  end

  test "unknown fields, wrong types and out-of-range values are refused, every reason at once" do
    errors = errors_for("model_id" => "eleven_v4", "speed" => 2, "style" => "0.1", "pitch" => 1,
      "use_speaker_boost" => "yes", "gain_db" => 30, "stability" => true)
    assert_equal 7, errors.size, errors.inspect
    assert(errors.any? { |e| e.include?("unknown field: pitch") })
    assert(errors.any? { |e| e.start_with?("model_id must be one of") })
    assert(errors.any? { |e| e.start_with?("speed must be") })
    assert(errors.any? { |e| e.start_with?("style must be") })
    assert(errors.any? { |e| e.start_with?("stability must be") })
    assert(errors.any? { |e| e.start_with?("use_speaker_boost") })
    assert(errors.any? { |e| e.start_with?("gain_db must be") })

    assert_equal [ "delivery must be an object" ], errors_for([ 1 ])
    assert(errors_for("speed" => Float::NAN).any? { |e| e.start_with?("speed must be") })
    assert(errors_for("speed" => Float::INFINITY).any? { |e| e.start_with?("speed must be") })
  end

  test "eleven_v3 takes stability 0, 0.5 or 1, checked after the defaults are applied" do
    assert_equal [ "eleven_v3 takes stability 0, 0.5 or 1 only" ], errors_for("stability" => 0.75)
    assert_equal [ "eleven_v3 takes stability 0, 0.5 or 1 only" ], errors_for("model_id" => "eleven_v3", "stability" => 0.3)
    assert VoiceDelivery.normalize!("stability" => 1)
    assert VoiceDelivery.normalize!("model_id" => "eleven_multilingual_v2", "stability" => 0.3)
  end

  test "the digest is over the effective values: key order and spelled-out defaults never change it" do
    a = VoiceDelivery.for(VoiceDelivery.normalize!(JANIS_TAKE_03))
    b = VoiceDelivery.for(VoiceDelivery.normalize!(JANIS_TAKE_03.to_a.reverse.to_h))
    assert_equal a.digest("v1"), b.digest("v1")
    assert_not_equal a.digest("v1"), a.digest("v2")

    assert_equal "v1:default", VoiceDelivery.for(nil).digest("v1")
    assert_equal "v1:default", VoiceDelivery.for(VoiceDelivery.normalize!("speed" => 1.0, "gain_db" => 0)).digest("v1")
    assert_not_equal "v1:default", VoiceDelivery.for(VoiceDelivery.normalize!("speed" => 0.9)).digest("v1")
  end

  # Tempo (JkMdAe): a slowdown after ElevenLabs, for a pace below its floor.
  # Unset or 1 changes nothing, and leaves every earlier digest as it was.
  test "tempo is optional, bounded 0.8 to 1, and only marks the digest when it changes the sound" do
    assert_nil VoiceDelivery.for(nil).tempo
    assert_equal 1.0, VoiceDelivery.for(nil).as_json["tempo"]
    assert_nil VoiceDelivery.for(VoiceDelivery.normalize!("tempo" => 1)).tempo

    slowed = VoiceDelivery.for(VoiceDelivery.normalize!(JANIS_TAKE_03.merge("speed" => 0.7, "tempo" => 0.93)))
    assert_equal 0.93, slowed.tempo
    assert_includes slowed.summary, "tempo 0.93 on Listen"

    assert(errors_for("tempo" => 0.65).any? { |e| e.start_with?("tempo must be") })
    assert(errors_for("tempo" => 1.1).any? { |e| e.start_with?("tempo must be") })
    assert(errors_for("tempo" => "0.9").any? { |e| e.start_with?("tempo must be") })

    take_03 = VoiceDelivery.for(VoiceDelivery.normalize!(JANIS_TAKE_03))
    assert_equal take_03.digest("v1"), VoiceDelivery.for(VoiceDelivery.normalize!(JANIS_TAKE_03.merge("tempo" => 1.0))).digest("v1")
    assert_not_equal take_03.digest("v1"), VoiceDelivery.for(VoiceDelivery.normalize!(JANIS_TAKE_03.merge("tempo" => 0.93))).digest("v1")
    assert_equal "v1:default", VoiceDelivery.for(VoiceDelivery.normalize!("tempo" => 1.0)).digest("v1")
    # The digest Janis's take 03 had before tempo existed, unchanged.
    assert_equal Digest::SHA256.hexdigest(take_03.as_json.except("tempo").sort.to_h.to_json)[0, 16], take_03.digest.split(":").last
  end

  test "an agent refuses an invalid delivery written straight to the column" do
    agent = agents(:research_assistant)
    agent.voice_delivery = { "speed" => 3 }
    assert_not agent.valid?
    assert agent.errors.full_messages_for(:voice_delivery).any?
  end

end
