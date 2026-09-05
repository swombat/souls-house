class Api::V1::Memory::RecallsController < Api::V1::Memory::BaseController

  rescue_from Mnemodyne::Embeddings::Unavailable, Mnemodyne::Recall::CapacityExceeded do
    render json: { error: "Recall temporarily unavailable" }, status: :service_unavailable
  end
  rescue_from Mnemodyne::Commit::InvalidReceipt do
    render json: { error: "Invalid or expired recall receipt" }, status: :unprocessable_entity
  end

  def create
    input = params.permit(:query, :automatic, :limit, seed_node_ids: [], node_activations: {}).to_h.symbolize_keys
    render json: Mnemodyne::Recall.new(vault: @vault, **input).call
  end

  def commit
    render json: { results: Mnemodyne::Commit.call(vault: @vault, receipt: params[:receipt],
      selected_node_ids: params[:selected_node_ids], reason: params[:reason]) }
  end

end
