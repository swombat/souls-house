class Agents::MemoriesController < ApplicationController

  include AgentScoped

  def create
    return redirect_locked_agent if @agent.externally_hosted?

    memory = @agent.memories.new(memory_params)

    if memory.save
      redirect_to edit_account_agent_path(current_account, @agent), notice: "Memory created"
    else
      redirect_to edit_account_agent_path(current_account, @agent),
                  inertia: { errors: memory.errors.to_hash }
    end
  end

  private

  def memory_params
    params.require(:memory).permit(:content, :memory_type)
  end

  def redirect_locked_agent
    redirect_to edit_account_agent_path(current_account, @agent, tab: "memory"),
      alert: "Memory is self-managed by the resident's external runtime"
  end

end
