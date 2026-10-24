# Shared tag handling for the Field API: reading `tag` filters and
# add/remove/set requests, and the answer when they're malformed.
module FieldTagsJson

  extend ActiveSupport::Concern

  private

  # `tag` filter values (repeatable: tag=a&tag=b, or tag[]=a). Renders 422 and
  # returns nil when malformed.
  def tag_params
    raw = params[:tag]
    raw = [] if raw.nil?
    raw = [ raw ] if raw.is_a?(String)
    unless raw.is_a?(Array) && raw.all? { |name| name.is_a?(String) }
      render json: { error: "tag must be a name, or repeated for several" }, status: :unprocessable_entity
      return nil
    end

    FieldTag.normalize_list(raw)
  rescue FieldTag::Invalid => e
    render json: { error: e.message }, status: :unprocessable_entity
    nil
  end

  # Records in `scope` that carry every one of `tags`.
  def with_all_tags(scope, tags)
    return scope if tags.empty?

    model = scope.klass
    ids = FieldTagging.kept.joins(:field_tag).merge(FieldTag.kept)
      .where(taggable_type: model.base_class.name, field_tags: { name: tags })
      .group(:taggable_id).having("count(DISTINCT field_tags.id) = ?", tags.size).select(:taggable_id)
    scope.where(id: ids)
  end

  # Applies add/remove/tags from the request to an item. Renders the answer.
  # Every list is checked as sent (FieldTag.list_param) before anything
  # changes; `tags: []` is a real request to clear the item's tags.
  def apply_tag_change(item, by:)
    add = FieldTag.list_param(params, :add)
    remove = FieldTag.list_param(params, :remove)
    set = FieldTag.list_param(params, :tags)
    if set.nil? && add.blank? && remove.blank?
      return render json: { error: "Provide add, remove, or tags (the whole list)" }, status: :unprocessable_entity
    end

    names = item.change_tags!(by: by, add: add || [], remove: remove || [], set: set)
    render json: { tags: names }
  rescue FieldTag::Invalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.record.errors.full_messages.to_sentence }, status: :unprocessable_entity
  end

end
