class Api::V1::Memory::NodesController < Api::V1::Memory::BaseController

  def index
    nodes = @vault.nodes.order(:id)
    nodes = nodes.where(node_type: params[:type]) if params[:type].present?
    nodes = nodes.where("id > ?", params[:after]) if params[:after].present?
    render json: { nodes: nodes.limit(bounded_limit).map { |node| node_json(node) } }
  end

  def show
    render json: { node: node_json(@vault.nodes.find(params[:id])) }
  end

  def create
    attributes = node_attributes
    render json: write("node:create", attributes) { { node: node_json(@vault.nodes.create!(attributes)) } }, status: :created
  end

  def update
    attributes = node_attributes
    render json: write("node:update:#{params[:id]}", attributes) {
      node = @vault.nodes.find(params[:id])
      node.update!(attributes)
      { node: node_json(node) }
    }
  end

  def destroy
    render json: write("node:destroy:#{params[:id]}", {}) {
      node = @vault.nodes.find(params[:id])
      if node.integration_state == "constitutional"
        raise Mnemodyne::Write::Conflict
      end
      node.destroy!
      # Keep retry keys, but erase historical handle/edge responses on forgetting.
      @vault.operations.where("result->'node'->>'id' = :id OR result->'edge'->>'source_id' = :id OR result->'edge'->>'target_id' = :id", id: node.id)
        .update_all(result: { forgotten: true })
      { deleted: true }
    }
  end

  private

  def node_attributes
    object_params(:node).permit(:node_type, :content, :description, :charge,
      :integration_state, :is_dormant, :disclosure, source_uris: [], metadata: {}).to_h
  end

end
