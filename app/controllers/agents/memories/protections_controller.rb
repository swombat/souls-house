class Agents::Memories::ProtectionsController < ApplicationController

  include AgentScoped

  before_action :set_memory

  def create
    return redirect_locked_agent if @agent.externally_hosted?

    @memory.update!(constitutional: true)
    audit("memory_protected", @memory)
    redirect_to edit_account_agent_path(current_account, @agent), notice: "Memory protected"
  end

  def destroy
    return redirect_locked_agent if @agent.externally_hosted?

    @memory.update!(constitutional: false)
    audit("memory_unprotected", @memory)
    redirect_to edit_account_agent_path(current_account, @agent), notice: "Memory unprotected"
  end

  private

  def set_memory
    @memory = @agent.memories.find(params[:memory_id])
  end

  def redirect_locked_agent
    redirect_to edit_account_agent_path(current_account, @agent, tab: "memory"),
      alert: "Memory is self-managed by the resident's external runtime"
  end

end
