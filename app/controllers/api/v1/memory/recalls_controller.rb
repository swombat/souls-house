class Api::V1::Memory::RecallsController < Api::V1::Memory::BaseController

  rescue_from Mnemodyne::Embeddings::Unavailable, Mnemodyne::Recall::CapacityExceeded do
    record_automatic_status("unavailable")
    render json: { error: "Recall temporarily unavailable" }, status: :service_unavailable
  end
  rescue_from Mnemodyne::Commit::InvalidReceipt do
    render json: { error: "Invalid or expired recall receipt" }, status: :unprocessable_entity
  end

  def create
    input = params.permit(:query, :automatic, :limit, seed_node_ids: [], node_activations: {}).to_h.symbolize_keys
    record_automatic_status("started")
    result = Mnemodyne::Recall.new(vault: @vault, **input).call
    record_automatic_status(result[:results].empty? ? "empty" : "ok")
    render json: result
  end

  def commit
    render json: { results: Mnemodyne::Commit.call(vault: @vault, receipt: params[:receipt],
      selected_node_ids: params[:selected_node_ids], reason: params[:reason]) }
  end

  private

  def record_automatic_status(status)
    return unless @vault && params[:automatic] == true
    # Content-free telemetry is not reinforcement and is excluded from exports.
    @vault.with_lock do
      @vault.update_columns(last_automatic_recall_at: Time.current, last_automatic_recall_status: status)
    end
    Rails.logger.info("Mnemodyne automatic recall: #{status}")
  end

end
