class Api::V1::Memory::EdgesController < Api::V1::Memory::BaseController

  def index
    edges = @vault.edges.order(:id)
    if params[:node_id].present?
      node = @vault.nodes.find(params[:node_id])
      edges = edges.where(source_id: node.id).or(edges.where(target_id: node.id))
    end
    edges = edges.where("id > ?", params[:after]) if params[:after].present?
    render json: { edges: edges.limit(bounded_limit).map { |edge| edge_json(edge) } }
  end

  def show
    render json: { edge: edge_json(@vault.edges.find(params[:id])) }
  end

  def create
    attributes = edge_attributes
    render json: write("edge:create", attributes) {
      @vault.nodes.find(attributes.fetch("source_id"))
      @vault.nodes.find(attributes.fetch("target_id"))
      { edge: edge_json(@vault.edges.create!(attributes)) }
    }, status: :created
  end

  def update
    attributes = object_params(:edge).permit(:weight, metadata: {}).to_h
    render json: write("edge:update:#{params[:id]}", attributes) {
      edge = @vault.edges.find(params[:id])
      edge.update!(attributes)
      { edge: edge_json(edge) }
    }
  end

  def destroy
    render json: write("edge:destroy:#{params[:id]}", {}) {
      @vault.edges.find(params[:id]).destroy!
      { deleted: true }
    }
  end

  private

  def edge_attributes
    object_params(:edge).permit(:source_id, :target_id, :edge_type, :weight, metadata: {}).to_h
  end

end
