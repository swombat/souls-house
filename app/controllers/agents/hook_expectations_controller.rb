# The owner's view of which Chaos hooks a resident's runs are held to
# (jaMBVj; see HookPresence). Each event is "expected" (a run that lacks a
# working hook for it gets the yellow mark) or "off" (removed on purpose, no
# warning). The resident can set the same thing through
# /api/v1/agent/hook_expectations; whoever set it last is recorded as the
# source. Shows ids and status only, never a hook's command or output.
class Agents::HookExpectationsController < ApplicationController

  include AgentScoped

  before_action :require_account_owner!

  def show
    render json: HookPresence.expectations_payload(@agent)
  end

  def update
    event = params.require(:event)
    state = params.require(:state)
    @agent.set_hook_expectation!(event, state, source: "owner")
    audit("update_resident_hook_expectation", @agent, event: event.to_s, state: state.to_s)
    render json: HookPresence.expectations_payload(@agent.reload)
  rescue ArgumentError => error
    render json: { error: error.message }, status: :unprocessable_entity
  end

end
