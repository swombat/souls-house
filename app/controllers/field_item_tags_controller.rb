# Adding and removing tags on one Field item from the page. The item is named
# by its page key ("file-abc", "recording-abc", "note-abc"). JSON.
class FieldItemTagsController < ApplicationController

  require_feature_enabled :agents

  KINDS = {
    "file" => ->(account) { account.field_files.kept },
    "recording" => ->(account) { account.field_recordings.kept },
    "note" => ->(account) { account.whiteboards.active }
  }.freeze

  def update
    kind, id = params.require(:item).to_s.split("-", 2)
    scope = KINDS[kind]
    raise ActiveRecord::RecordNotFound unless scope && id.present?

    item = scope.call(current_account).find(id)
    names = item.change_tags!(by: Current.user, add: FieldTag.list_param(params, :add) || [],
      remove: FieldTag.list_param(params, :remove) || [])
    render json: { tags: names, all_tags: FieldItems.tags_json(current_account) }
  rescue FieldTag::Invalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.record.errors.full_messages.to_sentence }, status: :unprocessable_entity
  end

end
