# A fixed standard-voice catalogue for tests that set a resident's voice.
module ElevenLabsVoicesStub

  STANDARD_VOICES = [
    ElevenLabsVoices::Voice.new(voice_id: "std-aria", name: "Aria", description: "Bright.",
      labels: { "accent" => "american", "gender" => "female" }, preview_url: nil),
    ElevenLabsVoices::Voice.new(voice_id: "std-brian", name: "Brian", description: "Deep.",
      labels: { "accent" => "british", "gender" => "male" }, preview_url: nil)
  ].freeze

  def with_standard_voices(voices = STANDARD_VOICES, &block)
    ElevenLabsVoices.stub(:catalogue, voices, &block)
  end

  LIBRARY_VOICES = [
    ElevenLabsVoices::Voice.new(voice_id: "own-janis", name: "Janis", description: "Cloned.",
      labels: {}, preview_url: nil)
  ].freeze

  # The account's own library, whatever account is asked about.
  def with_library_voices(voices = LIBRARY_VOICES, &block)
    ElevenLabsVoices.stub(:library, ->(_account) { voices }, &block)
  end

  def with_voice_list_unavailable(&block)
    ElevenLabsVoices.stub(:catalogue, -> { raise ElevenLabsVoices::Unavailable, "ElevenLabs voice list returned 503" }, &block)
  end

end
