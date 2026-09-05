class Agents::RuntimeChecksController < ApplicationController

  before_action :set_agent
  before_action :require_account_owner!

  def identity_export
    send_data AgentIdentityExporter.new(@agent).build,
      filename: "#{@agent.name.to_s.parameterize.presence || "agent-#{@agent.id}"}-identity.tar.gz",
      type: "application/gzip"
  end

  def send_test_request
    @agent.require_conversation_runtime!
    chat = current_account.chats.find_or_create_by!(title: "system: agent test for #{@agent.name}") do |record|
      record.model_id = "openrouter/auto"
      record.manual_responses = true
      record.agent_ids = [ @agent.id ]
    end
    chat.agents << @agent unless chat.agents.exists?(@agent.id)
    result = ExternalAgentResponseRequest.new(
      agent: @agent, chat: chat, requested_by: Current.user.email_address,
      initiation_reason: "Owner-requested runtime test"
    ).call
    render json: {
      status: result[:status].to_i.between?(200, 299) ? "runtime_reachable" : "transport_failed",
      transport_status: result[:status], conversation_id: chat.to_param,
      error: result.dig(:body, "error"), runtime_status: result.dig(:body, "status"),
      runtime_stderr: result.dig(:body, "stderr"), runtime_stdout: result.dig(:body, "stdout")
    }
  rescue Agent::RuntimeAvailability::Unavailable => e
    render json: { error: e.message, code: e.code }, status: :conflict
  end

  def send_orientation
    unless @agent.external? && @agent.health_state == "healthy"
      render json: { error: "Agent must be healthy and externally hosted before orientation" }, status: :unprocessable_entity
      return
    end

    @agent.update!(orientation_requested_at: Time.current)
    result = ExternalAgentOrientationRequest.new(
      agent: @agent, requested_by: Current.user.email_address
    ).call
    ok = result[:status].to_i.between?(200, 299)
    @agent.update!(orientation_completed_at: Time.current) if ok
    render json: {
      status: ok ? "orientation_sent" : "transport_failed",
      transport_status: result[:status], oriented: result[:oriented], oriented_at: result[:oriented_at],
      error: result[:error] || result.dig(:body, "error"), runtime_status: result.dig(:body, "status"),
      runtime_stderr: result.dig(:body, "stderr"), runtime_stdout: result.dig(:body, "stdout")
    }, status: ok ? :ok : :bad_gateway
  end

  private

  def set_agent
    @agent = current_account.agents.find(params[:id])
  end

end
