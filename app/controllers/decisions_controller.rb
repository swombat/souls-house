class DecisionsController < ApplicationController

  allow_unauthenticated_access

  def index
    @link_preview = LinkPreview.for(:decisions)
    render inertia: "decisions/index", props: { decisions: Decision.all.map { |decision| decision.except(:body_html) } }
  end

  def show
    decision = Decision.find(params[:slug])
    @link_preview = LinkPreview.for_decision(decision)
    render inertia: "decisions/show", props: { decision:, description: @link_preview.description }
  end

end
