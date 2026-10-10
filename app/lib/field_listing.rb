# One page of the Field list: files, notes and recordings merged newest first,
# narrowed by tab and tags, counted per tab. The page only loads the records it
# shows, so a Field with hundreds of recordings costs the same as one with ten.
class FieldListing

  PER_PAGE = 50
  KINDS = %w[file note recording].freeze
  TAB_KINDS = { "all" => KINDS, "files" => %w[file], "notes" => %w[note], "recordings" => %w[recording] }.freeze

  attr_reader :page, :pages, :counts

  def initialize(account:, tab:, tags: [], page: 1, per_page: PER_PAGE)
    @account = account
    @tab = TAB_KINDS.key?(tab) ? tab : "all"
    @tags = tags
    @per_page = per_page
    @counts = count_tabs
    @pages = [ (total.to_f / per_page).ceil, 1 ].max
    @page = page.to_i.clamp(1, @pages)
  end

  def total
    @counts.fetch(@tab)
  end

  # The records on this page, in order.
  def records
    @records ||= begin
      rows = page_rows
      loaded = rows.group_by(&:first).to_h do |kind, list|
        ids = list.map(&:last)
        [ kind, load(kind, ids).index_by(&:id) ]
      end
      rows.filter_map { |kind, id| loaded.dig(kind, id) }
    end
  end

  # The open item, wherever it sits in the list (it may be on another page,
  # or hidden by the tag filter, and still be the one being read).
  def self.find_item(account, key)
    kind, id = key.to_s.split("-", 2)
    return nil if id.blank?

    scope = { "file" => account.field_files.kept, "note" => account.whiteboards.active,
              "recording" => account.field_recordings.kept }[kind]
    scope&.find_by_obfuscated_id(id)
  end

  private

  def scope_for(kind)
    scope = case kind
    when "file" then @account.field_files.kept
    when "note" then @account.whiteboards.active
    else @account.field_recordings.kept
    end
    with_all_tags(scope)
  end

  def sort_column(kind)
    kind == "note" ? "COALESCE(whiteboards.last_edited_at, whiteboards.updated_at)" : "#{table(kind)}.created_at"
  end

  def table(kind)
    { "file" => "field_files", "note" => "whiteboards", "recording" => "field_recordings" }.fetch(kind)
  end

  def count_tabs
    per_kind = KINDS.to_h { |kind| [ kind, scope_for(kind).count ] }
    TAB_KINDS.transform_values { |kinds| kinds.sum { |kind| per_kind[kind] } }
  end

  # [[kind, id], ...] for this page only: one UNION over light columns.
  def page_rows
    return [] if total.zero?

    parts = TAB_KINDS.fetch(@tab).map do |kind|
      scope_for(kind).unscope(:order)
        .select(Arel.sql("#{ApplicationRecord.connection.quote(kind)} AS kind, #{table(kind)}.id AS item_id, #{sort_column(kind)} AS sort_at"))
        .to_sql
    end
    sql = "SELECT kind, item_id FROM (#{parts.join(' UNION ALL ')}) AS field_items " \
          "ORDER BY sort_at DESC, kind, item_id DESC LIMIT #{@per_page.to_i} OFFSET #{(@page - 1) * @per_page.to_i}"
    ApplicationRecord.connection.select_rows(sql).map { |kind, id| [ kind, id.to_i ] }
  end

  def load(kind, ids)
    case kind
    when "file" then @account.field_files.where(id: ids).includes(:uploaded_by, file_attachment: :blob)
    when "note" then @account.whiteboards.where(id: ids).includes(:last_edited_by)
    else @account.field_recordings.where(id: ids).includes(:uploaded_by, speakers: :field_voice)
    end
  end

  # Items carrying every chosen tag.
  def with_all_tags(scope)
    return scope if @tags.empty?

    ids = FieldTagging.kept.joins(:field_tag).merge(FieldTag.kept)
      .where(taggable_type: scope.klass.base_class.name, field_tags: { name: @tags, account_id: @account.id })
      .group(:taggable_id).having("count(DISTINCT field_tags.id) = ?", @tags.size).select(:taggable_id)
    scope.where(id: ids)
  end

end
