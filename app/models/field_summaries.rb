# Field summaries (Daniel, 2026-10-10): for every file and recording whose words
# the house can read, Claude Haiku 5.5, paid by the house, writes a few-word
# summary and a one-sentence summary.
#
# What is sent: the item's kind, title, note and its words (extracted text or
# transcript), cut to MAX_SOURCE_CHARS. It goes through the house's OpenRouter
# key, pinned to Anthropic with no fallback, the same route as the on-the-house
# resident model. Nothing else about the account is sent.
#
# Processing (checked 2026-10-10, Mira on #275): OpenRouter lists Anthropic as
# not training on prompts but retaining them for up to 30 days. data_collection
# "deny" excludes training providers; it is not zero retention. The Field page
# says so wherever summaries are on.
#
# On wherever the house has an inference key: there is deliberately no switch
# (Daniel, 2026-10-10). Without a key, nothing is contacted.
module FieldSummaries

  MODEL = "anthropic/claude-haiku-5.5"
  PROVIDER = "anthropic"
  MAX_SOURCE_CHARS = 24_000
  SHORT_MAX_WORDS = 5
  SHORT_MAX_CHARS = 80
  LONG_MAX_CHARS = 400
  # Dropped from the end of a trimmed short summary so it doesn't stop on a
  # dangling "and" or "the".
  TRAILING_FILLER = %w[
    a an and the of on in at to for with about or but by from
    et de du des la le les un une sur avec pour ou
  ].to_set.freeze

  SYSTEM = PromptTemplate.render("summarize_field_item", :system).freeze

  # Not a setting. Test credentials carry a house key, so test_helper turns
  # this off to keep tests that perform every queued job off the network.
  mattr_accessor :live, default: true

  module_function

  def enabled? = live && HouseInference::Offering.configured?

  # => { short:, long: }. Raises UtilityInference::Error when the call fails
  # or the answer can't be used.
  #
  # Haiku often answers the short one in six or seven words however the prompt
  # puts it (live, 2026-10-10: four of seven recordings were refused three
  # times and given up on). So a short one that is too long is not a failure:
  # it is asked for once more with its word count, and if that is still too
  # long the shorter answer is trimmed to five words.
  def summarize(item, inference: UtilityInference)
    user = user_prompt(item)
    summary = parse(ask(inference, user))
    return summary if short_fits?(summary[:short])

    second = begin
      parse(ask(inference, user + shorten_request(summary[:short])))[:short]
    rescue UtilityInference::InvalidResponse
      nil
    end
    return summary.merge(short: second) if second && short_fits?(second)

    summary.merge(short: trim_short([ second, summary[:short] ].compact.min_by { it.split.size }))
  end

  def ask(inference, user) = inference.house_chat(model: MODEL, provider: PROVIDER, system: SYSTEM, user: user)

  def shorten_request(short)
    "\nAn earlier answer's short summary, #{short.to_json}, has #{short.split.size} words. " \
      "Answer again with a short summary of at most #{SHORT_MAX_WORDS} words.\n"
  end

  def short_fits?(short) = short.split.size <= SHORT_MAX_WORDS && short.length <= SHORT_MAX_CHARS

  # The first five words, without a dangling filler word or punctuation at the
  # end, and within the column's length.
  def trim_short(short)
    words = short.split.first(SHORT_MAX_WORDS)
    words.pop while words.size > 1 && filler?(words[-1])
    words.join(" ").sub(DANGLING, "").truncate(SHORT_MAX_CHARS, separator: " ", omission: "")
  end

  DANGLING = /[\s,;:&–—-]+\z/
  def filler?(word) = (bare = word.sub(DANGLING, "")).empty? || TRAILING_FILLER.include?(bare.downcase)

  def user_prompt(item)
    source = item.summary_source.to_s
    truncated = source.length > MAX_SOURCE_CHARS
    PromptTemplate.render("summarize_field_item", :user,
      kind: item.is_a?(FieldRecording) ? "recording transcript" : "file",
      title: item.title.to_s, note: item.note.to_s,
      content: truncated ? "#{source[0, MAX_SOURCE_CHARS]}\n[… the rest is cut off]" : source)
  end

  # The model is asked for a JSON object; take the first one in the answer.
  # Both parts must be present. The short one's five words are held by
  # summarize, not here; "one sentence" is only asked for, and the long one is
  # capped by length, not checked for being a single sentence.
  def parse(answer)
    json = answer.to_s[/\{.*\}/m]
    data = json && JSON.parse(json)
    raise UtilityInference::InvalidResponse, "Summary answer is not an object" unless data.is_a?(Hash)

    short = clean(data["short"]).sub(/[.。]\z/, "")
    long = clean(data["sentence"])
    if short.empty? || long.empty?
      raise UtilityInference::InvalidResponse, "Summary answer has the wrong shape"
    end

    { short: short, long: long.truncate(LONG_MAX_CHARS, separator: " ") }
  rescue JSON::ParserError
    raise UtilityInference::InvalidResponse, "Summary answer is not JSON"
  end

  def clean(value) = value.is_a?(String) ? value.squish.delete_prefix('"').delete_suffix('"').strip : ""

end
