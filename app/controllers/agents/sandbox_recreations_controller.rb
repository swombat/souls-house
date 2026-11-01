class Agents::SandboxRecreationsController < ApplicationController

  include AgentScoped

  before_action :require_account_owner!

  def create
    unless @agent.externally_hosted?
      redirect_to edit_account_agent_path(current_account, @agent, tab: "settings"), alert: "Only hosted residents have sandboxes to recreate"
      return
    end

    HostedAgentRuntimeReconcileJob.perform_later(@agent.id, force: true)
    redirect_to edit_account_agent_path(current_account, @agent, tab: "settings"), notice: "Restarting #{@agent.name}. Their identity, memory and history are kept."
  end

end
