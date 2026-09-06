class RuntimeCommandPreview

  POLICY = JSON.parse(Rails.root.join("agent-runtime/command_preview_policy.json").read).freeze
  HIDDEN = "[arguments hidden]".freeze

  # Independently enforce the reporter's finite vocabulary. A callback field
  # named "preview" is not permission to persist arbitrary command text.
  def self.validated(value)
    return unless value.is_a?(String) && value.bytesize <= 240
    return value if value == "Command #{HIDDEN}"

    plain = value.delete_suffix(" #{HIDDEN}")
    words = plain.split(" ")
    return unless words.join(" ") == plain
    prefix = POLICY.keys.select { |candidate| words.first(candidate.split.size) == candidate.split }
      .max_by { |candidate| candidate.split.size }
    return unless prefix
    return unless (words.drop(prefix.split.size) - POLICY.fetch(prefix)).empty?

    value
  end

end
