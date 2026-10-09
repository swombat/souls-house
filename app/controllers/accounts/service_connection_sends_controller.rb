# What residents sent through a comms (WhatsApp) connection as its owner, and
# who was allowed to, as JSON for the owner's connection page (spec §5).
# Every send is listed, failed and unknown ones included: which resident,
# to whom, when, the text and the outcome. Only the owner sees this: not
# account admins (who can still withdraw grants and disconnect), other
# members, or residents.
class Accounts::ServiceConnectionSendsController < ApplicationController

  LIMIT = 200

  def show
    connection = current_account.service_connections.find_by_public_id!(params[:service_connection_id])
    raise ActiveRecord::RecordNotFound unless connection.owner?(Current.user)

    sends = connection.comms_sends.includes(:agent, :comms_chat).order(requested_at: :desc, id: :desc).limit(LIMIT)
    grants = connection.comms_send_grant_events.includes(:agent, :actor_user).order(created_at: :desc, id: :desc).limit(LIMIT)

    response.headers["Cache-Control"] = "no-store"
    render json: {
      service_connection_id: connection.public_id,
      senders: connection.agent_service_accesses.sending.includes(:agent).map { |access| { resident_id: access.agent.to_param, resident_name: access.agent.name } },
      sends: sends.map(&:as_owner_json),
      grant_history: grants.map(&:as_owner_json)
    }
  end

end
