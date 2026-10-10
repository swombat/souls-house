# Field summaries (Daniel, 2026-10-10): for every file and recording whose words
# the house can read, Claude Haiku 5.5, paid by the house, writes a few-word
# summary and a one-sentence summary.
#
# What is sent: the item's kind, title, note and its words (extracted text or
# transcript), cut to MAX_SOURCE_CHARS. It goes through the house's OpenRouter
# key, pinned to Anthropic with no fallback and data collection denied, the
# same route as the on-the-house resident model. Nothing else about the
# account is sent. SOULSHOUSE_FIELD_SUMMARIES=off stops every call.
module FieldSummaries

  MODEL = "anthropic/claude-haiku-5.5"
  PROVIDER = "anthropic"
  MAX_SOURCE_CHARS = 24_000
  SHORT_MAX_WORDS = 8
  SHORT_MAX_CHARS = 80
  LONG_MAX_CHARS = 400

  SYSTEM = PromptTemplate.render("summarize_field_item", :system).freeze

  module_function

  def enabled? = ENV["SOULSHOUSE_FIELD_SUMMARIES"] != "off" && HouseInference::Offering.configured?

  # => { short:, long: }. Raises UtilityInference::Error when the call fails
  # or the answer can't be used.
  def summarize(item, inference: UtilityInference)
    answer = inference.house_chat(model: MODEL, provider: PROVIDER, system: SYSTEM, user: user_prompt(item))
    parse(answer)
  end

  def user_prompt(item)
    source = item.summary_source.to_s
    truncated = source.length > MAX_SOURCE_CHARS
    PromptTemplate.render("summarize_field_item", :user,
      kind: item.is_a?(FieldRecording) ? "recording transcript" : "file",
      title: item.title.to_s, note: item.note.to_s,
      content: truncated ? "#{source[0, MAX_SOURCE_CHARS]}\n[… the rest is cut off]" : source)
  end

  # The model is asked for a JSON object; take the first one in the answer and
  # hold it to the shapes we display.
  def parse(answer)
    json = answer.to_s[/\{.*\}/m]
    data = json && JSON.parse(json)
    raise UtilityInference::InvalidResponse, "Summary answer is not an object" unless data.is_a?(Hash)

    short = clean(data["short"]).sub(/[.。]\z/, "")
    long = clean(data["sentence"])
    if short.empty? || long.empty? || short.split.size > SHORT_MAX_WORDS || short.length > SHORT_MAX_CHARS
      raise UtilityInference::InvalidResponse, "Summary answer has the wrong shape"
    end

    { short: short, long: long.truncate(LONG_MAX_CHARS, separator: " ") }
  rescue JSON::ParserError
    raise UtilityInference::InvalidResponse, "Summary answer is not JSON"
  end

  def clean(value) = value.is_a?(String) ? value.squish.delete_prefix('"').delete_suffix('"').strip : ""

end
