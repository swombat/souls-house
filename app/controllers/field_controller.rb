# The Field: material a person brings from their own life for the residents of
# this account to read. Files are new; notes are the former whiteboards.
class FieldController < ApplicationController

  require_feature_enabled :agents

  TABS = %w[all files notes recordings].freeze

  def index
    tab = TABS.include?(params[:tab]) ? params[:tab] : "all"
    listing = FieldListing.new(account: current_account, tab: tab, tags: filter_tags,
      page: params[:q].present? ? 1 : list_page)
    records = listing.records
    current = FieldListing.find_item(current_account, params[:item])
    tags = FieldTagging.names_for(records + [ current ])
    tags_for = ->(item) { tags[[ item.class.base_class.name, item.id ]] || [] }
    current_json = (item_json(current, tags_for.(current)) if current)

    render inertia: "field/index", props: {
      items: records.map { |record| item_json(record, tags_for.(record), content: false) },
      current_item: current_json,
      counts: listing.counts,
      field_empty: listing.counts["all"].zero? && filter_tags.empty?,
      pagination: { page: listing.page, pages: listing.pages, per_page: FieldListing::PER_PAGE, total: listing.total },
      tags: FieldItems.tags_json(current_account),
      filter_tags: filter_tags,
      query: params[:q].is_a?(String) ? params[:q].to_s.strip : "",
      search: search_props,
      recording_allowance: FieldItems.allowance_json(current_account),
      suggestions_enabled: FieldSuggestions.enabled?,
      summaries_enabled: FieldSummaries.enabled?,
      max_recording_bytes: FieldRecording::MAX_BYTES,
      max_recording_label: FieldRecording::MAX_BYTES_LABEL,
      tab: tab,
      selected: current_json&.dig(:key),
      max_file_bytes: FieldFile::MAX_FILE_SIZE,
      max_file_label: FieldFile::MAX_FILE_SIZE_LABEL,
      account_name: current_account.name,
      account: current_account.as_json
    }
  end

  private

  def list_page
    params[:page].is_a?(String) ? params[:page].to_i : 1
  end

  def item_json(record, tags, content: true)
    case record
    when FieldFile then FieldItems.file_json(record, tags)
    when FieldRecording then FieldItems.recording_json(record, tags)
    else FieldItems.note_json(record, tags, content: content)
    end
  end

  def filter_tags
    @filter_tags ||= parse_filter_tags
  end

  def parse_filter_tags
    raw = params[:tag]
    raw = [ raw ] if raw.is_a?(String)
    return [] unless raw.is_a?(Array) && raw.all?(String)

    FieldTag.normalize_list(raw)
  rescue FieldTag::Invalid
    []
  end

  # Results when the page was asked to search: words, tags, or both. The
  # item grid is filtered by tags on the page itself; only a query needs the
  # server.
  def search_props
    query = params[:q].is_a?(String) ? params[:q].strip : ""
    return nil if query.blank?

    page = FieldSearch.new(account: current_account, query: query, tags: filter_tags,
      sort: (params[:sort] if FieldSearch::SORTS.include?(params[:sort])), page: params[:page].is_a?(String) ? params[:page] : nil).call
    { results: page.results.map { |result| FieldItems.search_result_json(result) }, page: page.page, next_page: page.next_page, error: nil }
  rescue FieldSearch::Invalid => e
    { results: [], page: 0, next_page: nil, error: e.message }
  end

end
