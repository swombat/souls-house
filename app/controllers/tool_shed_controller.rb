class ToolShedController < ApplicationController

  allow_unauthenticated_access

  def index
    @link_preview = LinkPreview.for(:tool_shed)
    render inertia: "tool-shed/index", props: { tools: ToolShedEntry.all.map { |entry| entry.except(:body_html) } }
  end

  def show
    tool = ToolShedEntry.find(params[:slug])
    @link_preview = LinkPreview.for_tool_shed_entry(tool)
    render inertia: "tool-shed/show", props: { tool:, description: @link_preview.description }
  end

end
