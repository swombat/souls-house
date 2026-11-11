class FieldTable
  # One declared column and the value check for its type. Values are cast on
  # the way in, so a CSV "12" and a JSON 12 land as the same number, and
  # anything that doesn't fit the type is refused with the column named.
  class Column

    TYPES = %w[text number date boolean link].freeze
    KEY_FORMAT = /\A[a-z][a-z0-9_]*\z/
    TRUE_WORDS = %w[true yes y 1 on].freeze
    FALSE_WORDS = %w[false no n 0 off].freeze

    attr_reader :key, :label, :type

    def self.from_hash(hash)
      hash = hash.to_h.stringify_keys
      new(key: hash["key"], label: hash["label"], type: hash["type"])
    end

    def initialize(key:, label: nil, type: nil)
      @key = key.to_s
      @label = label.to_s.strip.presence || @key.tr("_", " ").capitalize
      @type = type.to_s.presence || "text"
    end

    def to_h
      { "key" => key, "label" => label, "type" => type }
    end

    # nil when fine, otherwise a readable reason.
    def problem(limits)
      return "Column key can't be blank" if key.blank?
      return "Column key #{key.inspect} is longer than #{limits.name_chars} characters" if key.length > limits.name_chars
      unless key.match?(KEY_FORMAT)
        return "Column key #{key.inspect} must be lower case letters, digits and underscores, starting with a letter"
      end
      return "Column label for #{key} is longer than #{limits.name_chars} characters" if label.length > limits.name_chars
      return "Column type #{type.inspect} for #{key} is not one of #{TYPES.join(', ')}" unless TYPES.include?(type)

      nil
    end

    # The stored form of value, or raises Invalid. nil and "" clear the cell.
    def cast(value)
      return nil if value.nil? || (value.is_a?(String) && value.strip.empty?)

      case type
      when "text" then cast_text(value)
      when "number" then cast_number(value)
      when "date" then cast_date(value)
      when "boolean" then cast_boolean(value)
      when "link" then cast_link(value)
      end
    end

    class Invalid < StandardError; end

    private

    def invalid!(value, expected)
      raise Invalid, "#{key} must be #{expected} (got #{value.inspect.truncate(60)})"
    end

    def cast_text(value)
      invalid!(value, "text") unless value.is_a?(String) || value.is_a?(Numeric) || value == true || value == false
      value.to_s
    end

    def cast_number(value)
      return value if value.is_a?(Integer)
      return (value.finite? ? value : invalid!(value, "a finite number")) if value.is_a?(Float)
      return cast_number(value.to_f) if value.is_a?(BigDecimal)
      invalid!(value, "a number") unless value.is_a?(String)

      text = value.strip
      return Integer(text, 10) if text.match?(/\A-?\d{1,300}\z/)
      return cast_number(Float(text)) if text.match?(/\A-?(\d+\.\d*|\.\d+|\d+)([eE][-+]?\d+)?\z/)

      invalid!(value, "a number")
    end

    # A calendar date (YYYY-MM-DD) or an ISO 8601 time, which keeps its offset.
    def cast_date(value)
      invalid!(value, "an ISO 8601 date like 2026-11-10") unless value.is_a?(String)
      text = value.strip
      if text.match?(/\A\d{4}-\d{2}-\d{2}\z/)
        Date.iso8601(text).iso8601
      else
        Time.iso8601(text).iso8601
      end
    rescue ArgumentError, Date::Error
      invalid!(value, "an ISO 8601 date like 2026-11-10")
    end

    def cast_boolean(value)
      return value if value == true || value == false

      word = value.to_s.strip.downcase
      return true if TRUE_WORDS.include?(word)
      return false if FALSE_WORDS.include?(word)

      invalid!(value, "true or false")
    end

    def cast_link(value)
      invalid!(value, "an http(s) link") unless value.is_a?(String)
      text = value.strip
      uri = URI.parse(text)
      invalid!(value, "an http(s) link") unless %w[http https].include?(uri.scheme) && uri.host.present?
      text
    rescue URI::InvalidURIError
      invalid!(value, "an http(s) link")
    end

  end
end
