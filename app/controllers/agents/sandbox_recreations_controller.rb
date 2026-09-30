class Agents::SandboxRecreationsController < ApplicationController

  include AgentScoped

  before_action :require_account_owner!

  def create
    unless @agent.externally_hosted?
      redirect_to edit_account_agent_path(current_account, @agent, tab: "hosting"), alert: "Only hosted residents have sandboxes to recreate"
      return
    end

    HostedAgentRuntimeReconcileJob.perform_later(@agent.id)
    redirect_to edit_account_agent_path(current_account, @agent, tab: "hosting"), notice: "Runtime image refresh queued for #{@agent.name}. Identity, session, repository, and work volumes will be preserved."
  end

end
