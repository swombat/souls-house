class Stone
  # Validation is not a JavaScript analyser. Executable documents must only be
  # served on the isolated domain under the independent browser sandbox/CSP.
  class InteractiveDocument < Document

    POLICY_VERSION = 2
    HTML_ELEMENTS = (Document::HTML_ELEMENTS + %w[
      script button input textarea label select option optgroup output canvas
      progress meter
    ]).freeze
    HTML_GLOBAL_ATTRIBUTES = (Document::HTML_GLOBAL_ATTRIBUTES + %w[tabindex hidden spellcheck]).freeze
    HTML_ATTRIBUTES = Document::HTML_ATTRIBUTES.merge(
      "script" => %w[type],
      "meta" => %w[charset name content http-equiv],
      "button" => %w[type disabled],
      "input" => %w[type value min max step checked disabled placeholder maxlength],
      "textarea" => %w[rows cols maxlength placeholder readonly disabled],
      "label" => %w[for],
      "select" => %w[multiple disabled],
      "option" => %w[value selected disabled],
      "optgroup" => %w[label disabled],
      "output" => %w[for],
      "canvas" => %w[width height],
      "progress" => %w[value max],
      "meter" => %w[value min max low high optimum]
    ).freeze

    private

    def validate_meta(node)
      # A document can tighten (never loosen) the HTTP policy. No refresh or
      # alternate charset/parser directives are accepted.
      return if node["http-equiv"]&.downcase == "content-security-policy" &&
        node["content"].present? && !node["charset"] && !node["name"]

      super
    end

    def validate_element(node)
      super
      if node.name == "input" && !%w[text number range checkbox radio button color].include?(node["type"] || "text")
        add_error("Unsupported input type")
      elsif node.name == "script" && node["type"] && !%w[text/javascript application/javascript module].include?(node["type"])
        add_error("Only inline JavaScript is supported")
      end
    end

  end
end
