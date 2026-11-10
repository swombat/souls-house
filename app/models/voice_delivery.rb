# How a resident's ElevenLabs voice is read aloud (eOyXXJ): which ElevenLabs
# model, the voice settings sent with each request, and a gain applied to the
# stored audio afterwards (ElevenLabs has no loudness setting). Stored on
# agents.voice_delivery; nil there means the house defaults, and the request
# body is then exactly what it was before delivery existed.
#
# A stored delivery holds only the fields someone set. Each field left out
# falls back to the default, so {"speed" => 0.8} changes speed alone.
class VoiceDelivery

  class Invalid < StandardError

    attr_reader :errors

    def initialize(errors)
      @errors = errors
      super(errors.join("; "))
    end

  end

  DEFAULT_MODEL_ID = "eleven_v3"
  # Verified ElevenLabs text-to-speech ids only. Speed is sent on every one;
  # whether eleven_v3 honours it is not documented, so we say "sent".
  MODEL_IDS = %w[eleven_v3 eleven_multilingual_v2 eleven_flash_v2_5 eleven_turbo_v2_5].freeze
  # eleven_v3 takes three stability settings only (Creative, Natural, Robust).
  V3_STABILITIES = [ 0.0, 0.5, 1.0 ].freeze

  DEFAULT_VOICE_SETTINGS = {
    stability: 0.5,
    similarity_boost: 0.75,
    style: 0.0,
    use_speaker_boost: true,
    speed: 1.0
  }.freeze

  UNIT_RANGE = (0.0..1.0)
  SPEED_RANGE = (0.7..1.2)
  GAIN_RANGE = (-12.0..12.0)
  # A pitch-preserving slowdown after ElevenLabs renders, for a pace below its
  # speed floor (JkMdAe: take 03 at 0.70 with tempo 0.93 is about 0.65).
  TEMPO_RANGE = (0.8..1.0)
  RANGES = {
    "speed" => SPEED_RANGE, "stability" => UNIT_RANGE, "similarity_boost" => UNIT_RANGE,
    "style" => UNIT_RANGE, "gain_db" => GAIN_RANGE, "tempo" => TEMPO_RANGE
  }.freeze
  FIELDS = (%w[model_id use_speaker_boost] + RANGES.keys).freeze

  # The stored hash for these fields, or Invalid with every reason at once.
  # Blank input (nil or {}) is nil: the house defaults.
  def self.normalize!(input)
    return nil if input.nil?

    input = input.to_unsafe_h if input.respond_to?(:to_unsafe_h)
    raise Invalid, [ "delivery must be an object" ] unless input.is_a?(Hash)

    input = input.transform_keys(&:to_s)
    errors = []
    unknown = input.keys - FIELDS
    errors << "unknown field#{"s" if unknown.size > 1}: #{unknown.sort.join(", ")}" if unknown.any?

    out = {}
    if input.key?("model_id")
      model = input["model_id"]
      if MODEL_IDS.include?(model)
        out["model_id"] = model
      else
        errors << "model_id must be one of #{MODEL_IDS.join(", ")}"
      end
    end
    RANGES.each do |field, range|
      next unless input.key?(field)

      number = numeric(input[field])
      if number && range.cover?(number)
        out[field] = number
      else
        errors << "#{field} must be a number from #{range.min} to #{range.max}"
      end
    end
    if input.key?("use_speaker_boost")
      if [ true, false ].include?(input["use_speaker_boost"])
        out["use_speaker_boost"] = input["use_speaker_boost"]
      else
        errors << "use_speaker_boost must be true or false"
      end
    end

    effective = new(out)
    if errors.empty? && effective.model_id == "eleven_v3" && !V3_STABILITIES.include?(effective.voice_settings[:stability].to_f)
      errors << "eleven_v3 takes stability 0, 0.5 or 1 only"
    end
    raise Invalid, errors if errors.any?

    out.presence
  end

  def self.numeric(value)
    return nil if value == true || value == false
    return value.to_f if value.is_a?(Numeric) && value.to_f.finite?

    nil
  end
  private_class_method :numeric

  def self.for(stored)
    new(stored || {})
  end

  def initialize(stored)
    @stored = (stored || {}).transform_keys(&:to_s).freeze
  end

  DEFAULT = new({}).freeze

  def model_id
    @stored["model_id"] || DEFAULT_MODEL_ID
  end

  def voice_settings
    DEFAULT_VOICE_SETTINGS.to_h do |key, default|
      [ key, @stored.fetch(key.to_s, default) ]
    end
  end

  def gain_db
    @stored.fetch("gain_db", 0.0).to_f
  end

  def gain?
    !gain_db.zero?
  end

  # nil when unset or 1.0: Listen's audio keeps ElevenLabs' pace.
  def tempo
    value = @stored["tempo"]&.to_f
    value unless value.nil? || value == 1.0
  end

  # What changes the sound: a cache key part for the preview, and the mark on
  # stored Listen audio, so audio made under another delivery is made again.
  # Taken over the effective values, canonically, so {} and {"speed" => 1.0}
  # are one sound and key order never costs another render. The defaults
  # digest to "default". Tempo joins the digest only when it changes the
  # sound, so audio made before tempo existed keeps its mark.
  def digest(voice_id = nil)
    effective = as_json
    effective.delete("tempo") if tempo.nil?
    default = DEFAULT.as_json.except("tempo")
    part = effective == default ? "default" : Digest::SHA256.hexdigest(effective.sort.to_h.to_json)[0, 16]
    [ voice_id, part ].compact.join(":")
  end

  def default?
    digest == "default"
  end

  # Every effective value, for the API and the Appearance line.
  def as_json(*)
    { "model_id" => model_id }
      .merge(voice_settings.transform_keys(&:to_s).transform_values { |v| v.is_a?(Numeric) ? v.to_f : v })
      .merge("gain_db" => gain_db, "tempo" => tempo || 1.0)
  end

  def summary
    settings = voice_settings
    parts = [ model_id, "speed #{fmt(settings[:speed])}", "stability #{fmt(settings[:stability])}",
      "similarity #{fmt(settings[:similarity_boost])}", "style #{fmt(settings[:style])}" ]
    parts << "speaker boost off" unless settings[:use_speaker_boost]
    parts << format("%+g dB on Listen", gain_db) if gain?
    parts << "tempo #{fmt(tempo)} on Listen" if tempo
    parts.join(" · ")
  end

  private

  def fmt(number)
    format("%g", number)
  end

end
