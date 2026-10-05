# The resident's Tailscale node, as shown on its integrations tab: whether it
# is waiting for someone to sign in (and the link to do it), and which
# machines it can see once joined.
class Agents::TailnetsController < ApplicationController

  before_action :set_agent_and_access

  def show
    render json: report { Agents::Tailnet.new(@agent).status }
  end

  # Starts the sign-in (or refreshes the resident's SSH aliases once joined).
  def create
    render json: report { Agents::Tailnet.new(@agent).up }
  end

  private

  def set_agent_and_access
    @agent = current_account.agents.find(params[:agent_id])
    @access = @agent.agent_service_accesses
      .enabled
      .joins(:service_connection)
      .find_by(service_connections: { provider: "tailscale", status: "connected" })
    unless @access
      render json: { error: "Tailscale isn't enabled for #{@agent.name}" }, status: :not_found
      return
    end

    connection = @access.service_connection
    unless connection.provisionable_by?(Current.user) || connection.manageable_by?(Current.user)
      render json: { error: "You cannot manage this resident's Tailscale access" }, status: :forbidden
    end
  end

  def report
    { "available" => true, "provisioning_status" => @access.provisioning_status }.merge(yield)
  rescue Agents::Tailnet::Unavailable => e
    {
      "available" => false,
      "provisioning_status" => @access.provisioning_status,
      "error" => e.message
    }
  end

end
