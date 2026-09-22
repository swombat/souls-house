class Agents::MemoryOverviewsController < ApplicationController
  include AgentScoped

  def show
    response.headers["Cache-Control"] = "private, no-store"
    render json: Agents::MemoryOverview.new(@agent).call
  end

  def history
    return head :forbidden unless Current.user.is_site_admin?

    response.headers["Cache-Control"] = "private, no-store"
    kinds = params.key?(:kinds) ? params[:kinds].to_s.split(",") : Agents::MemoryHistory::KINDS
    render json: Agents::MemoryHistory.new(@agent).call(kinds: kinds, cursor: params[:cursor])
  rescue Agents::MemoryHistory::InvalidRequest
    render json: { error: "Invalid or expired history request. Return to the newest page." }, status: :bad_request
  end
end
