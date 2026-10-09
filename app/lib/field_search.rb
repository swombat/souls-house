# Search across one account's Field: recordings, files and notes.
#
# Matching is Postgres full text with the `simple` configuration over each
# item's search_vector (title, note, body; see the migration): every word
# must appear, "a phrase" in quotes matches the words in order, -word
# excludes. Case-insensitive, no stemming. A query may be left out when tags
# are given, which lists everything carrying those tags.
#
# Results are dated, newest first (or by relevance), PAGE_SIZE at a time, and
# carry up to three excerpts from the item's body with the matched words
# marked by character offsets.
#
# Transcripts are searched only once ready (transcript_text is written in the
# same update that makes a recording ready); the body excerpt for anything
# else is its note.
class FieldSearch

  PAGE_SIZE = 20
  MAX_QUERY_LENGTH = 200
  MAX_TAGS = 10
  KINDS = %w[recording file note].freeze
  SORTS = %w[newest relevance].freeze
  BODY_LIMIT = 128_000 # the migration's body cap (bytes there; excerpts read this many characters)

  # Markers ts_headline puts around matches and between fragments. Control
  # characters, so they can't collide with text a person wrote (extracted
  # text and transcripts keep tabs and newlines, never these three).
  START_SEL = "\u0002"
  STOP_SEL = "\u0003"
  FRAGMENT_DELIMITER = "\u0001"
  HEADLINE_OPTIONS = "MaxFragments=3, MaxWords=35, MinWords=15, ShortWord=2, " \
    "StartSel=#{START_SEL}, StopSel=#{STOP_SEL}, FragmentDelimiter=#{FRAGMENT_DELIMITER}".freeze

  class Invalid < StandardError; end

  Result = Data.define(:kind, :record, :date, :rank, :tags, :excerpts)
  Page = Data.define(:results, :page, :next_page)

  # kind => [model, table, date SQL, kept SQL, body SQL]
  SOURCES = {
    "recording" => {
      model: "FieldRecording", table: "field_recordings",
      # When it was recorded, if known (archive imports carry it), else when
      # it came into the Field.
      date: "COALESCE(field_recordings.recorded_at, field_recordings.created_at)",
      kept: "field_recordings.discarded_at IS NULL",
      body: "concat_ws(E'\\n\\n', field_recordings.note, CASE WHEN field_recordings.status = 'ready' THEN field_recordings.transcript_text END)"
    },
    "file" => {
      model: "FieldFile", table: "field_files",
      date: "field_files.created_at",
      kept: "field_files.discarded_at IS NULL",
      body: "concat_ws(E'\\n\\n', field_files.note, field_files.extracted_text)"
    },
    "note" => {
      model: "Whiteboard", table: "whiteboards",
      date: "COALESCE(whiteboards.last_edited_at, whiteboards.updated_at)",
      kept: "whiteboards.deleted_at IS NULL",
      body: "concat_ws(E'\\n\\n', whiteboards.summary, whiteboards.content)"
    }
  }.freeze

  def initialize(account:, query: nil, tags: [], kinds: nil, sort: nil, page: nil)
    @account = account
    @query = query.to_s.strip
    @tags = FieldTag.normalize_list(tags)
    @kinds = Array(kinds).presence || KINDS
    @sort = sort.presence || "newest"
    @page = page.presence ? Integer(page.to_s, 10, exception: false) : 0
    validate!
  rescue FieldTag::Invalid => e
    raise Invalid, e.message
  end

  def call
    rows = connection.select_all(page_sql).to_a
    has_more = rows.size > PAGE_SIZE
    rows = rows.first(PAGE_SIZE)

    records = load_records(rows)
    excerpts = @query.present? ? load_excerpts(rows) : {}
    found = rows.filter_map { |row| records[[ row["kind"], row["id"] ]] && row }
    tags = FieldTagging.names_for(found.map { |row| records[[ row["kind"], row["id"] ]] })

    results = found.map do |row|
      record = records[[ row["kind"], row["id"] ]]
      Result.new(
        kind: row["kind"], record: record, date: row["item_date"], rank: row["rank"].to_f,
        tags: tags[[ record.class.base_class.name, record.id ]] || [],
        excerpts: excerpts[[ row["kind"], row["id"] ]] || []
      )
    end

    Page.new(results: results, page: @page, next_page: (has_more ? @page + 1 : nil))
  end

  # "a \u0002b\u0003 c" -> { text: "a b c", matches: [[2, 1]] }. Runs of
  # whitespace (transcript line breaks) become one space; offsets are into
  # the returned text.
  def self.parse_fragment(fragment)
    text = +""
    matches = []
    fragment.split(/(#{START_SEL}.*?#{STOP_SEL})/o).each do |piece|
      marked = piece.start_with?(START_SEL)
      chunk = piece.delete(START_SEL + STOP_SEL).gsub(/\s+/, " ")
      chunk = chunk.lstrip if text.empty? || (text.end_with?(" ") && chunk.start_with?(" "))
      next if chunk.empty?

      if marked
        word = chunk.strip
        offset = text.length + chunk.index(word)
        matches << [ offset, word.length ] unless word.empty?
      end
      text << chunk
    end
    { text: text.rstrip, matches: matches }
  end

  private

  attr_reader :account

  def connection = ActiveRecord::Base.connection

  def validate!
    raise Invalid, "Give a query, a tag, or both" if @query.blank? && @tags.empty?
    raise Invalid, "query must be at most #{MAX_QUERY_LENGTH} characters" if @query.length > MAX_QUERY_LENGTH
    raise Invalid, "query can't contain NUL" if @query.include?("\0")
    raise Invalid, "At most #{MAX_TAGS} tags" if @tags.size > MAX_TAGS
    raise Invalid, "kind must be one of #{KINDS.join(", ")}" unless (@kinds - KINDS).empty?
    raise Invalid, "sort must be one of #{SORTS.join(", ")}" unless SORTS.include?(@sort)
    raise Invalid, "page must be a whole number from 0" if @page.nil? || @page.negative?
    if @query.present? && connection.select_value(sanitize("SELECT numnode(websearch_to_tsquery('simple', ?))", @query)).to_i.zero?
      raise Invalid, "The query has no words to search for"
    end
  end

  def page_sql
    unions = @kinds.map { |kind| kind_sql(kind) }.join(" UNION ALL ")
    order = @sort == "relevance" ? "rank DESC, item_date DESC, kind, id DESC" : "item_date DESC, kind, id DESC"
    "SELECT * FROM (#{unions}) AS found ORDER BY #{order} LIMIT #{PAGE_SIZE + 1} OFFSET #{@page * PAGE_SIZE}"
  end

  def kind_sql(kind)
    source = SOURCES.fetch(kind)
    table = source[:table]
    rank = @query.present? ? "ts_rank(#{table}.search_vector, websearch_to_tsquery('simple', #{quote(@query)}))" : "0"
    conditions = [ sanitize("#{table}.account_id = ?", account.id), source[:kept] ]
    conditions << "#{table}.search_vector @@ websearch_to_tsquery('simple', #{quote(@query)})" if @query.present?
    conditions << tag_condition(source) if @tags.any?

    "SELECT #{quote(kind)} AS kind, #{table}.id AS id, #{source[:date]} AS item_date, #{rank} AS rank " \
      "FROM #{table} WHERE #{conditions.join(" AND ")}"
  end

  # Items carrying every one of the tags.
  def tag_condition(source)
    sanitize(<<~SQL.squish, source[:model], account.id, @tags, @tags.size)
      #{source[:table]}.id IN (
        SELECT field_taggings.taggable_id FROM field_taggings
        JOIN field_tags ON field_tags.id = field_taggings.field_tag_id
        WHERE field_taggings.taggable_type = ? AND field_taggings.discarded_at IS NULL
          AND field_tags.discarded_at IS NULL AND field_tags.account_id = ? AND field_tags.name IN (?)
        GROUP BY field_taggings.taggable_id
        HAVING count(DISTINCT field_tags.id) = ?
      )
    SQL
  end

  def load_records(rows)
    rows.group_by { |row| row["kind"] }.each_with_object({}) do |(kind, list), memo|
      model = SOURCES.fetch(kind)[:model].constantize
      scope = model.where(id: list.map { |row| row["id"] })
      scope = scope.includes(:uploaded_by) if model.reflect_on_association(:uploaded_by)
      scope = scope.includes(file_attachment: :blob) if model == FieldFile
      scope.each { |record| memo[[ kind, record.id ]] = record }
    end
  end

  def load_excerpts(rows)
    rows.group_by { |row| row["kind"] }.each_with_object({}) do |(kind, list), memo|
      source = SOURCES.fetch(kind)
      sql = sanitize(
        "SELECT #{source[:table]}.id, ts_headline('simple', left(#{source[:body]}, #{BODY_LIMIT}), " \
        "websearch_to_tsquery('simple', ?), ?) AS headline FROM #{source[:table]} WHERE #{source[:table]}.id IN (?)",
        @query, HEADLINE_OPTIONS, list.map { |row| row["id"] }
      )
      connection.select_rows(sql).each do |(id, headline)|
        memo[[ kind, id ]] = excerpts_from(headline)
      end
    end
  end

  # No marked word means ts_headline found nothing in the body (the match was
  # in the title) and returned the opening words; that isn't an excerpt.
  def excerpts_from(headline)
    return [] if headline.blank? || !headline.include?(START_SEL)

    headline.split(FRAGMENT_DELIMITER).select { |fragment| fragment.include?(START_SEL) }
      .map { |fragment| self.class.parse_fragment(fragment) }
      .reject { |excerpt| excerpt[:text].blank? }
  end

  def quote(value) = connection.quote(value)
  def sanitize(*args) = ActiveRecord::Base.sanitize_sql_array(args)

end
