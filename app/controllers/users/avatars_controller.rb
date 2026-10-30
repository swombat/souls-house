class Users::AvatarsController < ApplicationController

  # A picture as a file (picked, dropped or pasted) or as a web address the
  # house fetches. Errors come back under `avatar` so the dialog can show them.
  def update
    attachable = AvatarAttachable.from(file: params[:avatar], url: params[:url])
    if Current.user.update_settings({}, { avatar: attachable })
      audit_with_changes(:set_avatar, Current.user)
      respond_ok("Avatar updated")
    else
      respond_error(Current.user.errors.full_messages.to_sentence)
    end
  rescue AvatarAttachable::Error, RemoteImageFetch::Error => e
    respond_error(e.message)
  end

  def destroy
    Current.user.profile&.retire_avatar!
    audit(:remove_avatar, Current.user)

    respond_ok("Avatar removed successfully")
  end

  private

  def respond_ok(notice)
    inertia_request? ?
      redirect_with_inertia_flash(:success, notice, edit_user_path) :
      render(json: { success: true, avatar_url: Current.user.reload.avatar_url }, status: :ok)
  end

  def respond_error(message)
    inertia_request? ?
      redirect_to(edit_user_path, inertia: { errors: { avatar: message } }) :
      render(json: { errors: [ message ] }, status: :unprocessable_entity)
  end

  def inertia_request?
    request.headers["X-Inertia"].present?
  end

end
