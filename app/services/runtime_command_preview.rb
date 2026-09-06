require "shellwords"
require "uri"

class RuntimeCommandPreview

  POLICY = JSON.parse(Rails.root.join("agent-runtime/command_preview_policy.json").read).freeze
  SENSITIVE = Regexp.new(POLICY.fetch("sensitive_name"), Regexp::IGNORECASE)
  PATTERNS = POLICY.fetch("secret_patterns").map { |pattern| Regexp.new(pattern) }.freeze
  REDACTED = "[REDACTED]".freeze

  # Defense in depth for the already-redacted preview, not a claim that
  # arbitrary secrets can always be recognised. Never accept raw output fields.
  def self.validated(value)
    return unless value.is_a?(String) && value.bytesize <= 1_024
    return if value.match?(/[\x00-\x1f\x7f\u202a-\u202e\u2066-\u2069]/)
    return "Command [payload hidden]" if value.match?(/`|\$\(|<\(|>\(|<</)

    words = Shellwords.split(value)
    hide_next = false
    executable = nil
    positional_seen = false
    result = words.map do |word|
      if %w[; && || | &].include?(word)
        executable = nil
        positional_seen = false
        hide_next = false
        next word
      end
      if hide_next
        hide_next = false
        next REDACTED
      end
      if word.match?(/\A[A-Za-z_][A-Za-z0-9_]*=/)
        next "#{word.split("=", 2).first}=#{REDACTED}"
      end
      if executable.nil?
        executable = File.basename(word)
      elsif %w[sed awk].include?(executable) && !word.start_with?("-") && !positional_seen
        positional_seen = true
        next REDACTED
      end
      if (%w[curl wget].include?(executable) && word.match?(/\A-[HudFb].+/)) ||
          (POLICY.fetch("script_commands").include?(executable) && word.match?(/\A-[ce].+/))
        next word.first(2) + REDACTED
      end
      name, assignment = word.split("=", 2)
      private_flag = POLICY.fetch("private_value_flags").include?(name) || (name.start_with?("-") && name.match?(SENSITIVE))
      script_flag = (POLICY.fetch("script_commands") + POLICY.fetch("shells") + %w[sed awk]).include?(executable) &&
        (POLICY.fetch("script_flags") + [ "-lc" ]).include?(name)
      if private_flag || script_flag
        name = "--[sensitive-option]" if private_flag && !POLICY.fetch("private_value_flags").include?(name)
        hide_next = assignment.nil?
        next assignment ? "#{name}=#{REDACTED}" : name
      end
      if %w[bearer basic].include?(word.downcase) || (word == "runner" && %w[rails bundle].include?(executable))
        hide_next = true
      end
      scrub(word)
    end
    result.map { |word| quote(word) }.join(" ").truncate_bytes(1_024)
  rescue ArgumentError
    nil
  end

  def self.scrub(word)
    if word.match?(/\A[A-Za-z][A-Za-z0-9+.-]*:\/\//)
      word = word.sub(%r{\A([A-Za-z][A-Za-z0-9+.-]*://)[^/@]*@}, '\1')
        .sub(/[?#].*\z/, "?#{REDACTED}")
    end
    return REDACTED if word.match?(/(authorization|cookie)\s*:/i)
    if word.match?(/[=:]/) && word.split(/[=:]/, 2).first.match?(SENSITIVE)
      return "#{word.split(/[=:]/, 2).first}=#{REDACTED}"
    end
    PATTERNS.each { |pattern| word = word.gsub(pattern, REDACTED) }
    word
  end

  def self.quote(word)
    return word unless word.match?(/\s|['"\\]/)
    '"' + word.gsub("\\", "\\\\\\\\").gsub('"', '\\"') + '"'
  end
  private_class_method :scrub, :quote

end
