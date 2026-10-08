class DecisionsController < ApplicationController

  allow_unauthenticated_access

  def index
    render inertia: "decisions/index", props: { decisions: Decision.all.map { |decision| decision.except(:body_html) } }
  end

  def show
    render inertia: "decisions/show", props: { decision: Decision.find(params[:slug]) }
  end

end
