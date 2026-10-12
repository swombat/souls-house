# Field swarm search: many small readers, one per item, asked one question.
#
# Expensive by design. Field search (FieldSearch) is the everyday tool; this
# is for deeper research, when an answer may be phrased in words a keyword
# search won't find. Off for every account until a site admin turns it on
# (Account#field_swarm_enabled, Site Admin → Accounts) while its cost is
# measured: every search and every reader call is recorded
# (FieldSwarmSearch, FieldSwarmRead).
#
# 1. Candidates: the account's kept items carrying every tag (required),
#    optionally of some kinds, whose title and text match `grep`, a
#    PostgreSQL regular expression (case-sensitive; start it with (?i) to
#    ignore case). Newest first.
# 2. Each item's text (the same text Field search reads: notes, transcript
#    once ready, a file's extracted text, a note's summary and content, a
#    tweet) is cut into parts of PART_CHARS that overlap by PART_OVERLAP (so
#    a passage on a seam is whole in one part), and each part goes to its own
#    reader with the question inside a fixed wrapper
#    (app/prompts/field_swarm_read). At most MAX_READS parts per search; an
#    item that doesn't fit whole is not started, and the response says how
#    many matched and how many were read. At most MAX_PARTS_PER_ITEM parts of
#    one item are read; the rest of a longer item is reported as unread.
# 3. Readers run CONCURRENCY at a time, all within DEADLINE. Each answers
#    "no", "extract_enough" or "read_whole", with an extract and verbatim
#    quotes. Every quote is looked up in the item's text: found ones come back
#    with their character offset in the item's text (TEXT_FIELDS, joined by a
#    blank line) and in the field it falls in; missing ones are marked
#    unverified.
#
# Expense caps hold under concurrency: a search is admitted, and its row
# written, under a lock on the account row, so two callers can't both take
# the last search of the day; the read cap is applied to the text actually
# loaded, not to lengths measured a query earlier. Every reader call is bound
# by a wall-clock deadline (not only socket timeouts), and threads still
# running at the deadline are stopped. A call that may have been billed but
# whose cost didn't come back is counted as uncertain, never as free.
#
# A part that wasn't read (the call failed, was rate limited, or time ran
# out) is reported as such: "nothing found" and "not checked" are different
# answers, and the summary says which items are incomplete.
#
# Readers: Claude Haiku 5.5 through the house's OpenRouter key, pinned to
# Anthropic with no fallback and data_collection "deny" (the route Field
# summaries and OCR use), so the house pays and the ledger shows it.
class FieldSwarm

  MODEL = "anthropic/claude-haiku-5.5"
  PROVIDER = "anthropic"
  MAX_TOKENS = 1_200

  # ~10k tokens a part: small enough that a reader attends to all of it.
  PART_CHARS = 40_000
  PART_OVERLAP = 400
  MAX_PARTS_PER_ITEM = 12
  MAX_READS = 100
  # Calls in flight at once. Chosen against the house's Anthropic input-token
  # rate limit (BYOK, so Anthropic's limits apply): 12 parts of ~10k tokens
  # every few seconds stays near 2M input tokens a minute at the worst. Not
  # measured against the house's tier yet; a 429 is reported, not retried.
  CONCURRENCY = 12
  # The web proxy closes a request at 120 s (config/deploy.yml).
  DEADLINE = 90
  READ_TIMEOUT = 45
  MIN_READ_TIME = 5
  # Seconds given to a thread to finish recording after it is told to stop.
  STOP_GRACE = 1
  MAX_QUESTION_LENGTH = 2_000
  MAX_GREP_LENGTH = 500
  MAX_SEARCHES_PER_ACCOUNT_PER_DAY = 40
  GREP_TIMEOUT_MS = 5_000
  MAX_QUOTES = 5
  MAX_QUOTE_CHARS = 300
  MAX_EXTRACT_CHARS = 2_000

  VERDICTS = %w[no extract_enough read_whole].freeze
  RANK = { "read_whole" => 0, "extract_enough" => 1, "unchecked" => 2, "no" => 3 }.freeze

  SYSTEM = PromptTemplate.render("field_swarm_read", :system).freeze

  # SQL for each kind's title, on top of FieldSearch::SOURCES.
  TITLES = {
    "recording" => "field_recordings.title",
    "file" => "concat_ws(' ', field_files.title, field_files.indexed_filename)",
    "tweet" => "field_tweets.author_handle",
    "note" => "whiteboards.name"
  }.freeze

  class Invalid < StandardError; end
  class Disabled < StandardError; end
  class LimitReached < StandardError; end

  # The reader: anything answering like UtilityInference.house_read. Tests
  # replace it (test_helper refuses live calls).
  mattr_accessor :reader, default: ->(**args) { UtilityInference.house_read(**args) }
  # The time limits, as accessors so tests can shrink them.
  mattr_accessor :deadline, default: DEADLINE
  mattr_accessor :read_timeout, default: READ_TIMEOUT
  mattr_accessor :min_read_time, default: MIN_READ_TIME

  # The fields an item's text is made of, in order, joined by a blank line
  # with missing (nil) fields left out: the same text as
  # FieldSearch::SOURCES[kind][:body]. A recording's transcript counts only
  # once it is ready.
  TEXT_FIELDS = {
    "recording" => %w[note notes transcript_text],
    "file" => %w[note extracted_text],
    "tweet" => %w[text],
    "note" => %w[summary content]
  }.freeze
  SEPARATOR = "\n\n"

  class ReadTimedOut < StandardError; end

  Part = Data.define(:kind, :id, :part, :parts, :from, :text)
  # An item's text and where each field sits in it.
  Text = Data.define(:text, :fields) do
    def length = text.length

    # => [field name, offset within that field] when the span at `offset`
    # of `length` characters lies wholly inside one field; nil when it
    # crosses a separator (then only the composite offset applies).
    def field_at(offset, length = 0)
      fields.each do |name, from, size|
        return [ name, offset - from ] if offset >= from && offset + length <= from + size
      end
      nil
    end
  end

  # How many parts a text of `length` characters is read in.
  def self.part_count(length)
    return 1 if length <= PART_CHARS

    1 + ((length - PART_CHARS).to_f / (PART_CHARS - PART_OVERLAP)).ceil
  end

  # The item's text as the swarm reads it, built from the record's fields.
  def self.text_for(kind, record)
    fields = []
    text = +""
    TEXT_FIELDS.fetch(kind).each do |name|
      value = record.public_send(name)
      value = nil if kind == "recording" && name == "transcript_text" && record.status != "ready"
      next if value.nil?

      text << SEPARATOR unless fields.empty?
      fields << [ name, text.length, value.length ]
      text << value
    end
    Text.new(text: text, fields: fields)
  end

  def initialize(account:, question:, tags:, grep: nil, kinds: nil, agent: nil, user: nil)
    @account = account
    @question = question.to_s.strip
    @tags = FieldTag.normalize_list(tags)
    @grep = grep.to_s.presence
    @kinds = Array(kinds).presence || FieldSearch::KINDS
    @agent = agent
    @user = user
    validate!
  rescue FieldTag::Invalid => e
    raise Invalid, e.message
  end

  def call
    raise Disabled, "Field swarm search is not enabled for this account" unless @account.field_swarm_enabled?

    started = monotonic
    search = admit!
    begin
      matched = candidates
      planned, not_started = plan(matched)
      records = load_records(planned.map { |row| [ row[:kind], row[:id] ] })
      texts = planned.each_with_object({}) do |row, memo|
        record = records[[ row[:kind], row[:id] ]]
        memo[[ row[:kind], row[:id] ]] = record ? self.class.text_for(row[:kind], record) : Text.new(text: "", fields: [])
      end
      # The cap is applied again to the text as loaded: a body can have grown
      # since its length was measured.
      planned, overflow = plan(planned.map { |row| row.merge(chars: texts[[ row[:kind], row[:id] ]].length) })
      not_started = overflow + not_started
      parts = planned.flat_map { |row| split(row, texts[[ row[:kind], row[:id] ]].text) }
      raise "read cap exceeded" if parts.size > MAX_READS # plan guarantees this; never send past it

      search.update!(matched_items: matched.size, candidate_items: planned.size, planned_reads: parts.size)
      outcomes = run(parts, planned, started)
      record!(search, parts, outcomes, started)
    rescue Invalid
      # Refused before any reader was sent (a grep that took too long): it
      # doesn't use up one of the day's searches.
      search.destroy!
      raise
    rescue StandardError
      search.update_columns(status: "failed", elapsed_ms: ((monotonic - started) * 1000).round)
      raise
    end
    response(search, matched, planned, not_started, texts, parts, outcomes)
  end

  # Where `quote` sits in `text`: exactly, or with any run of whitespace
  # standing for any other. => [offset, length] or nil.
  def self.locate(text, quote)
    quote = quote.to_s.strip
    return if quote.empty?

    if (offset = text.index(quote))
      return [ offset, quote.length ]
    end

    pattern = Regexp.new(quote.split(/\s+/).map { |word| Regexp.escape(word) }.join("\\s+"))
    match = pattern.match(text)
    [ match.begin(0), match[0].length ] if match
  end

  # The reader's answer, or nil when it isn't the JSON asked for: a known
  # verdict, string fields, a list of string quotes, and for a relevant
  # verdict an extract and at least one quote.
  def self.parse(text)
    json = text.to_s[/\{.*\}/m]
    answer = json && JSON.parse(json)
    return unless answer.is_a?(Hash) && VERDICTS.include?(answer["verdict"])
    return unless %w[extract why].all? { |key| answer[key].nil? || answer[key].is_a?(String) }

    quotes = answer["quotes"]
    return unless quotes.nil? || (quotes.is_a?(Array) && quotes.all?(String))

    verdict = answer["verdict"]
    extract = answer["extract"].to_s.strip
    quotes = Array(quotes).map(&:strip).reject(&:empty?)
    return if verdict != "no" && (extract.empty? || quotes.empty?)

    {
      verdict: verdict,
      extract: extract[0, MAX_EXTRACT_CHARS],
      why: answer["why"].to_s.strip[0, MAX_EXTRACT_CHARS],
      quotes: verdict == "no" ? [] : quotes.first(MAX_QUOTES).map { |quote| quote[0, MAX_QUOTE_CHARS] }
    }
  rescue JSON::ParserError
    nil
  end

  private

  def validate!
    raise Invalid, "Give a question" if @question.blank?
    raise Invalid, "question must be at most #{MAX_QUESTION_LENGTH} characters" if @question.length > MAX_QUESTION_LENGTH
    raise Invalid, "Give at least one tag: a swarm search reads only items carrying all of its tags" if @tags.empty?
    raise Invalid, "At most #{FieldSearch::MAX_TAGS} tags" if @tags.size > FieldSearch::MAX_TAGS
    raise Invalid, "kind must be one of #{FieldSearch::KINDS.join(", ")}" unless (@kinds - FieldSearch::KINDS).empty?
    return unless @grep

    raise Invalid, "grep must be at most #{MAX_GREP_LENGTH} characters" if @grep.length > MAX_GREP_LENGTH
    raise Invalid, "grep can't contain NUL" if @grep.include?("\0")
    connection.transaction(requires_new: true) do
      connection.select_value(sanitize("SELECT '' ~ ?", @grep))
    end
  rescue ActiveRecord::StatementInvalid
    raise Invalid, "grep is not a valid PostgreSQL regular expression"
  end

  def connection = ActiveRecord::Base.connection
  def sanitize(*args) = ActiveRecord::Base.sanitize_sql_array(args)
  def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  # Counts today's searches and writes this one's row under a lock on the
  # account row, so concurrent callers are admitted one at a time and the
  # daily cap can't be overshot. The lock is released before anything is read
  # or sent.
  def admit!
    @account.with_lock do
      if FieldSwarmSearch.where(account: @account, created_at: Time.current.utc.all_day).count >= MAX_SEARCHES_PER_ACCOUNT_PER_DAY
        raise LimitReached, "This account has used its #{MAX_SEARCHES_PER_ACCOUNT_PER_DAY} swarm searches for today (UTC)"
      end

      FieldSwarmSearch.create!(account: @account, agent: @agent, user: @user, tags: @tags, grep: @grep,
        question_chars: @question.length, model_id: MODEL)
    end
  end

  # => [{ kind:, id:, date:, chars: }], newest first.
  def candidates
    unions = @kinds.map { |kind| candidate_sql(kind) }.join(" UNION ALL ")
    sql = "SELECT * FROM (#{unions}) AS found ORDER BY item_date DESC NULLS LAST, kind, id DESC"
    rows = connection.transaction(requires_new: true) do
      connection.execute("SET LOCAL statement_timeout = #{GREP_TIMEOUT_MS}")
      connection.select_all(sql).to_a
    end
    rows.map { |row| { kind: row["kind"], id: row["id"], date: row["item_date"], chars: row["chars"].to_i } }
  rescue ActiveRecord::QueryCanceled
    raise Invalid, "grep took too long; make it more specific or add a tag"
  end

  def candidate_sql(kind)
    source = FieldSearch::SOURCES.fetch(kind)
    table = source[:table]
    conditions = [ sanitize("#{table}.account_id = ?", @account.id), source[:kept],
      FieldSearch.tag_condition(source, account_id: @account.id, tags: @tags) ]
    conditions << sanitize("concat_ws(E'\\n\\n', #{TITLES.fetch(kind)}, #{source[:body]}) ~ ?", @grep) if @grep

    "SELECT #{connection.quote(kind)} AS kind, #{table}.id AS id, #{source[:date]} AS item_date, " \
      "char_length(coalesce(#{source[:body]}, '')) AS chars FROM #{table} WHERE #{conditions.join(" AND ")}"
  end

  # Whole items, newest first, while their parts fit in MAX_READS. An item
  # with no text is skipped (nothing to read). => [planned, not_started]
  def plan(rows)
    budget = MAX_READS
    planned = []
    not_started = []
    rows.each do |row|
      next if row[:chars].zero?

      parts = [ self.class.part_count(row[:chars]), MAX_PARTS_PER_ITEM ].min
      if parts <= budget && not_started.empty?
        planned << row
        budget -= parts
      else
        not_started << row
      end
    end
    [ planned, not_started ]
  end

  def split(row, text)
    count = self.class.part_count(text.length)
    read = [ count, MAX_PARTS_PER_ITEM ].min
    (0...read).map do |index|
      from = index * (PART_CHARS - PART_OVERLAP)
      Part.new(kind: row[:kind], id: row[:id], part: index + 1, parts: count, from: from, text: text[from, PART_CHARS])
    end
  end

  # Runs the readers. Touches no database: results are recorded afterwards
  # on this thread. => one outcome hash per part, in order.
  def run(parts, planned, started)
    records = load_records(planned.map { |row| [ row[:kind], row[:id] ] })
    rows = planned.index_by { |row| [ row[:kind], row[:id] ] }
    prompts = parts.map do |part|
      key = [ part.kind, part.id ]
      record = records[key]
      PromptTemplate.render("field_swarm_read", :user, question: @question, kind: part.kind,
        title: (record ? record_title(part.kind, record) : "").to_s.squish, date: rows[key][:date]&.to_date&.iso8601,
        part: part.part, parts: part.parts, from: part.from + 1, to: part.from + part.text.length,
        total: rows[key][:chars], content: part.text)
    end

    outcomes = Array.new(parts.size)
    sent_at = Array.new(parts.size)
    queue = Queue.new
    parts.each_index { |index| queue << index }
    workers = Array.new([ CONCURRENCY, parts.size ].min) do
      Thread.new do
        while (index = (queue.pop(true) rescue nil))
          sent_at[index] = monotonic
          outcomes[index] = read(prompts[index], started)
        end
      end
    end
    # Each read bounds itself; this is the backstop. Nothing outlives the
    # deadline: a thread still running is stopped, and its part is counted as
    # timed out (possibly billed) or not run.
    stop_at = started + deadline + STOP_GRACE
    workers.each { |worker| worker.join([ stop_at - monotonic, 0 ].max) }
    workers.each { |worker| worker.kill if worker.alive? }
    workers.each { |worker| worker.join(STOP_GRACE) }
    outcomes.each_index do |index|
      next if outcomes[index]

      outcomes[index] = if sent_at[index]
        { status: "timed_out", error: "time ran out", sent: true, latency_ms: ((monotonic - sent_at[index]) * 1000).round }
      else
        { status: "unrun", error: "time ran out" }
      end
    end
    outcomes
  end

  # One reader call, bound by the time left before the deadline (a wall-clock
  # limit, not only the client's socket timeouts, which a slow trickle of
  # bytes never trips). `sent:` is whether the call may have been billed.
  def read(prompt, started)
    remaining = deadline - (monotonic - started)
    return { status: "unrun", error: "time ran out" } if remaining < min_read_time

    limit = [ read_timeout, remaining ].min
    began = monotonic
    answer = Timeout.timeout(limit, ReadTimedOut) do
      reader.call(model: MODEL, provider: PROVIDER, system: SYSTEM, user: prompt,
        max_tokens: MAX_TOKENS, timeout: limit.ceil)
    end
    latency = ((monotonic - began) * 1000).round
    base = { usage: answer[:usage], upstream_id: answer[:id], latency_ms: latency, sent: true }
    if (parsed = self.class.parse(answer[:text]))
      base.merge(status: "read", answer: parsed)
    else
      base.merge(status: "failed", error: "the reader's answer wasn't the JSON asked for")
    end
  rescue ReadTimedOut
    { status: "timed_out", error: "time ran out", sent: true, latency_ms: ((monotonic - began) * 1000).round }
  rescue UtilityInference::RateLimited
    # A 429 is refused before any work, so it isn't billed.
    { status: "rate_limited", error: "rate limited", sent: false, latency_ms: ((monotonic - began) * 1000).round }
  rescue UtilityInference::MissingCredentials, UtilityInference::InputTooLong => e
    { status: "failed", error: e.message, sent: false, latency_ms: 0 }
  rescue UtilityInference::Error => e
    { status: "failed", error: e.message, sent: true, latency_ms: began && ((monotonic - began) * 1000).round }
  rescue StandardError => e
    # A reader must never take the whole search down with it.
    { status: "failed", error: "reader error (#{e.class})", sent: true, latency_ms: began && ((monotonic - began) * 1000).round }
  end

  def load_records(keys)
    @records ||= keys.group_by(&:first).each_with_object({}) do |(kind, list), memo|
      FieldSearch::SOURCES.fetch(kind)[:model].constantize.where(id: list.map(&:last)).each do |record|
        memo[[ kind, record.id ]] = record
      end
    end
  end

  def record_title(kind, record) = kind == "note" ? record.name : record.title

  def record!(search, parts, outcomes, started)
    now = Time.current
    rows = parts.zip(outcomes).filter_map do |part, outcome|
      next if outcome[:status] == "unrun"

      tokens = outcome[:usage].is_a?(Hash) ? outcome[:usage] : {}
      cost, = HouseInference::UsageCost.call(outcome[:usage])
      outcome[:cost] = cost
      # Sent, and no cost came back: it may have been billed. Never free.
      uncertain = outcome[:sent] == true && cost.nil?
      {
        field_swarm_search_id: search.id, account_id: @account.id, item_kind: part.kind, item_id: part.id,
        part: part.part, parts: part.parts, input_chars: part.text.length, status: outcome[:status],
        verdict: outcome.dig(:answer, :verdict), error: outcome[:error]&.truncate(200),
        input_tokens: tokens["prompt_tokens"], output_tokens: tokens["completion_tokens"], cost_usd: cost,
        latency_ms: outcome[:latency_ms], upstream_id: outcome[:upstream_id], cost_uncertain: uncertain,
        created_at: now, updated_at: now
      }
    end
    FieldSwarmRead.insert_all!(rows) if rows.any?

    search.update!(
      status: "complete",
      completed_reads: outcomes.count { |outcome| outcome[:status] == "read" },
      failed_reads: outcomes.count { |outcome| %w[failed rate_limited timed_out].include?(outcome[:status]) },
      unrun_reads: outcomes.count { |outcome| outcome[:status] == "unrun" },
      uncertain_cost_reads: rows.count { |row| row[:cost_uncertain] },
      input_tokens: rows.sum { |row| row[:input_tokens].to_i },
      output_tokens: rows.sum { |row| row[:output_tokens].to_i },
      cost_usd: rows.sum { |row| row[:cost_usd] || 0 },
      elapsed_ms: ((monotonic - started) * 1000).round
    )
  end

  def response(search, matched, planned, not_started, texts, parts, outcomes)
    by_item = parts.zip(outcomes).group_by { |part, _| [ part.kind, part.id ] }
    records = load_records(planned.map { |row| [ row[:kind], row[:id] ] })
    tags = FieldTagging.names_for(records.values)

    items = planned.filter_map do |row|
      key = [ row[:kind], row[:id] ]
      record = records[key]
      next unless record

      item_json(row, record, tags, texts[key], by_item[key] || [])
    end
    items.sort_by!.with_index { |item, index| [ RANK.fetch(item[:verdict]), index ] }

    unread = outcomes.count { |outcome| outcome[:status] != "read" }
    cut_items = items.count { |item| item[:parts] > item[:parts_planned] }
    notes = []
    notes << "#{not_started.size} matching item(s) weren't read: the limit is #{MAX_READS} reads (parts of #{PART_CHARS} characters) per search. Narrow the tags or the grep, or ask again with a grep that excludes what you've read." if not_started.any?
    notes << "#{unread} part(s) weren't checked (failed, rate limited or out of time); the items they belong to are marked incomplete, and \"no\" for them means only that the parts read held nothing." if unread.positive?
    notes << "#{cut_items} long item(s) were read only in their first #{MAX_PARTS_PER_ITEM} parts." if cut_items.positive?
    notes << "Nothing matched the tags#{" and grep" if @grep}." if matched.empty?

    {
      items: items,
      summary: {
        id: search.id, matched_items: matched.size, read_items: planned.size, not_started_items: not_started.size,
        empty_items: matched.count { |row| row[:chars].zero? },
        planned_reads: parts.size, completed_reads: search.completed_reads, failed_reads: search.failed_reads,
        unrun_reads: search.unrun_reads, complete: not_started.empty? && unread.zero? && cut_items.zero?,
        relevant_items: items.count { |item| %w[read_whole extract_enough].include?(item[:verdict]) },
        cost_usd: search.cost_usd.to_d.round(6).to_s("F"), uncertain_cost_reads: search.uncertain_cost_reads,
        input_tokens: search.input_tokens, output_tokens: search.output_tokens, elapsed_ms: search.elapsed_ms,
        model: MODEL
      },
      notes: notes
    }
  end

  def item_json(row, record, tags, text, reads)
    result = FieldSearch::Result.new(kind: row[:kind], record: record, date: row[:date], rank: 0,
      tags: tags[[ record.class.base_class.name, record.id ]] || [], excerpts: [])
    base = FieldItems.search_result_json(result).except(:excerpts, :key)
    answered = reads.select { |_, outcome| outcome[:status] == "read" }
    verdict = answered.map { |_, outcome| outcome[:answer][:verdict] }.min_by { |v| RANK.fetch(v) }
    verdict ||= "unchecked"
    relevant = answered.reject { |_, outcome| outcome[:answer][:verdict] == "no" }
    multi = reads.size > 1

    base.merge(
      verdict: verdict,
      extract: relevant.map { |part, outcome| [ (multi ? "Part #{part.part}: " : nil), outcome[:answer][:extract] ].join }.reject(&:blank?).join("\n\n").presence,
      why: relevant.map { |_, outcome| outcome[:answer][:why] }.reject(&:blank?).join(" ").presence,
      locators: relevant.flat_map { |part, outcome| locators(text, part, outcome[:answer][:quotes]) }.uniq,
      text_chars: text.length,
      parts: reads.first&.first&.parts || 1,
      parts_planned: reads.size,
      parts_read: answered.size,
      complete: answered.size == reads.size && reads.size == (reads.first&.first&.parts || 1),
      errors: reads.reject { |_, outcome| outcome[:status] == "read" }.map { |part, outcome| { part: part.part, status: outcome[:status], error: outcome[:error] } }.presence
    ).compact
  end

  # Quotes looked up first in the part the reader saw, then anywhere in the
  # item. `offset` is into the item's whole text (TEXT_FIELDS joined by a
  # blank line); `field` and `field_offset` say where that is in the record's
  # own field (`content`, `transcript_text`...), for slicing that field. A
  # quote that crosses from one field into the next has no field
  # coordinates, only the composite offset.
  def locators(text, part, quotes)
    quotes.map do |quote|
      found = self.class.locate(part.text, quote)
      offset = found && part.from + found[0]
      found ||= self.class.locate(text.text, quote)
      offset ||= found&.first
      if found
        field, field_offset = text.field_at(offset, found[1])
        { quote: text.text[offset, found[1]], offset: offset, length: found[1], field: field, field_offset: field_offset,
          verified: true }.compact
      else
        { quote: quote, verified: false }
      end
    end
  end

end
