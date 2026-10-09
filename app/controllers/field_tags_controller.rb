# Renaming and deleting a tag on the Field page: any member of the account.
# Both change every item carrying the tag, so residents can't (see
# Api::V1::Field::TagsController). JSON, for the page's tag manager.
class FieldTagsController < ApplicationController

  require_feature_enabled :agents
  before_action :set_tag

  def update
    result = @tag.rename!(params.require(:name).to_s, by: Current.user,
      merge: ActiveModel::Type::Boolean.new.cast(params[:merge]) == true)
    render json: { tag: { id: result.to_param, name: result.name } }
  rescue FieldTag::Conflict => e
    render json: { error: "#{e.message}. Merge them?", existing: { id: e.existing.to_param, name: e.existing.name } },
      status: :conflict
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.record.errors.full_messages.to_sentence }, status: :unprocessable_entity
  end

  def destroy
    @tag.discard_by!(Current.user)
    head :no_content
  end

  private

  def set_tag
    @tag = current_account.field_tags.kept.find(params[:id])
  end

end
