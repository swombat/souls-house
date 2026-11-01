# A resident's picture: uploaded (picked, dropped or pasted) or fetched from
# a pasted web address. Saved straight away, like a person's avatar, so the
# Appearance tab's other fields are not submitted with it.
class Agents::AvatarsController < ApplicationController

  require_feature_enabled :agents
  before_action :set_agent

  def update
    @agent.avatar = AvatarAttachable.from(file: params[:avatar], url: params[:url])
    if @agent.save
      audit(:set_agent_avatar, @agent)
      @agent.touch # the account list and open conversations redraw with the new face
      @agent.sync_telegram_photo_later
      respond_ok("Picture updated")
    else
      respond_error(@agent.errors.full_messages_for(:avatar).to_sentence.presence || @agent.errors.full_messages.to_sentence)
    end
  rescue AvatarAttachable::Error, RemoteImageFetch::Error => e
    respond_error(e.message)
  end

  def destroy
    @agent.retire_avatar!
    audit(:remove_agent_avatar, @agent)
    @agent.touch
    @agent.sync_telegram_photo_later
    respond_ok("Picture removed")
  end

  private

  def set_agent
    @agent = current_account.agents.find(params[:id])
  end

  def back_path
    edit_account_agent_path(current_account, @agent, tab: "appearance")
  end

  def respond_ok(notice)
    inertia_request? ?
      redirect_with_inertia_flash(:success, notice, back_path) :
      render(json: { success: true, avatar_url: @agent.reload.avatar_url }, status: :ok)
  end

  def respond_error(message)
    inertia_request? ?
      redirect_to(back_path, inertia: { errors: { avatar: message } }) :
      render(json: { errors: [ message ] }, status: :unprocessable_entity)
  end

  def inertia_request?
    request.headers["X-Inertia"].present?
  end

end
