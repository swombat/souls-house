class Api::V1::Memory::VaultsController < Api::V1::Memory::BaseController

  skip_before_action :require_vault!, only: [ :show, :create ]

  def show
    vault = @resident.memory_vault
    readable = vault && !vault.suspended_at?
    indexed = if readable && Mnemodyne::Embeddings.configured?
      vault.nodes.where(embedding_profile: Mnemodyne::Embeddings.profile).where.not(embedding: nil).count
    else
      0
    end
    render json: { enabled: vault.present?, suspended: vault&.suspended_at?,
      auto_preview_enabled: !!(vault && !vault.suspended_at? && !vault.erasure_requested_at?),
      erasure_requested_at: vault&.erasure_requested_at, erase_after: vault&.erase_after,
      last_automatic_recall_at: vault&.last_automatic_recall_at,
      last_automatic_recall_status: vault&.last_automatic_recall_status,
      embedding_configured: Mnemodyne::Embeddings.configured?, indexed_nodes: indexed,
      resident_uuid: @resident.uuid, nodes: readable ? vault.nodes.count : nil, edges: readable ? vault.edges.count : nil }
  end

  def create
    @vault = Mnemodyne::Provision.call(@resident, deliberate: params[:automatic_lifecycle] != true)
    show
  end

  def request_erasure
    Mnemodyne::Erasure.request(@vault, receipt: params[:export_receipt], confirmation: params[:confirmation],
      include_constitutional: params.fetch(:include_constitutional, false))
    show
  end

  def cancel_erasure
    Mnemodyne::Erasure.cancel(@vault)
    show
  end

  def update
    value = params.require(:auto_preview_enabled)
    raise ArgumentError unless [ true, false ].include?(value)
    unless value
      return render json: { error: "Recall is a hosted lifecycle reflex. Use node disclosure or dormancy to govern what surfaces." }, status: :conflict
    end
    @vault.with_lock do
      raise Mnemodyne::Write::Conflict if @vault.erasure_requested_at? || @vault.suspended_at?
      @vault.update!(auto_preview_enabled: value)
    end
    show
  end

end
