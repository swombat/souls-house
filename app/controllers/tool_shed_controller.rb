class ToolShedController < ApplicationController

  allow_unauthenticated_access

  def index
    render inertia: "tool-shed/index", props: { tools: ToolShedEntry.all.map { |entry| entry.except(:body_html) } }
  end

  def show
    render inertia: "tool-shed/show", props: { tool: ToolShedEntry.find(params[:slug]) }
  end

end
