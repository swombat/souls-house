class Accounts::VisualTagsController < ApplicationController

  before_action :require_account_manager!

  def create
    tag = current_account.visual_tags.create!(visual_tag_params)
    audit(:create_visual_tag, tag)
    redirect_to account_interface_path(current_account), notice: "Visual tag added"
  rescue ActiveRecord::RecordInvalid => error
    redirect_validation_errors(error.record)
  end

  def update
    tag = VisualTag.resolve_for(current_account, params[:id])
    tag.update!(visual_tag_params)
    audit_with_changes(:update_visual_tag, tag)
    redirect_to account_interface_path(current_account), notice: "Visual tag updated"
  rescue ActiveRecord::RecordInvalid => error
    redirect_validation_errors(error.record)
  end

  def destroy
    tag = VisualTag.resolve_for(current_account, params[:id])
    tag.destroy!
    audit(:destroy_visual_tag, tag)
    redirect_to account_interface_path(current_account), notice: "Visual tag removed"
  rescue ActiveRecord::InvalidForeignKey
    redirect_to account_interface_path(current_account),
      inertia: { errors: { visual_tag: "This tag was selected while it was being removed. Please try again." } }
  end

  private

  def visual_tag_params
    params.require(:visual_tag).permit(:label, :icon, :colour)
  end

  def redirect_validation_errors(tag)
    redirect_to account_interface_path(current_account), inertia: { errors: tag.errors.to_hash }
  end

end
