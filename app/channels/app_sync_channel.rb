# The native app's chat stream (issue #94 B, step 6). Subscribing needs a
# ticket connection and the same authority as the HTTP API: a live device
# session and current confirmed membership of the conversation's account. The
# stream carries only `changed {latest_revision}` (Message::Revisioned), so a
# subscriber in the race before its disconnect learns only that something
# changed; content comes back through the checked API.
#
# Revocation and membership loss disconnect the connection after commit
# (AppSession, Membership, Account). A disconnect broadcast can land before a
# new connection is listening for it, so each subscription also rechecks its
# authority on a timer; no race leaves a subscription authorised for longer.
class AppSyncChannel < ApplicationCable::Channel

  RECHECK_INTERVAL = 30.seconds

  periodically :recheck_authority, every: RECHECK_INTERVAL

  def subscribed
    return reject unless current_app_session

    @conversation = find_conversation
    return reject unless @conversation && authorised?

    stream_from Message::Revisioned.stream_name(@conversation.id)
  end

  def unsubscribed
    stop_all_streams
  end

  private

  def find_conversation
    Chat.app_accessible_to(current_user).find(params[:conversation_id])
  rescue ActiveRecord::RecordNotFound, Hashids::InputError
    nil
  end

  def authorised?
    AppSession.live.exists?(id: current_app_session.id) &&
      Chat.app_accessible_to(current_user).exists?(id: @conversation.id)
  end

  def recheck_authority
    return if authorised?

    stop_all_streams
    connection.close(reason: ActionCable::INTERNAL[:disconnect_reasons][:unauthorized], reconnect: AppSession.live.exists?(id: current_app_session.id))
  end

end
