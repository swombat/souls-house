class Api::V1::Memory::VaultsController < Api::V1::Memory::BaseController

  skip_before_action :require_vault!, only: [ :show, :create ]

  def show
    vault = @resident.memory_vault
    indexed = if vault && Mnemodyne::Embeddings.configured?
      vault.nodes.where(embedding_profile: Mnemodyne::Embeddings.profile).where.not(embedding: nil).count
    else
      0
    end
    render json: { enabled: vault.present?, suspended: vault&.suspended_at?,
      auto_preview_enabled: vault&.auto_preview_enabled? || false,
      erasure_requested_at: vault&.erasure_requested_at, erase_after: vault&.erase_after,
      embedding_configured: Mnemodyne::Embeddings.configured?, indexed_nodes: indexed,
      resident_uuid: @resident.uuid, nodes: vault&.nodes&.count || 0, edges: vault&.edges&.count || 0 }
  end

  def create
    @resident.with_lock do
      @vault = @resident.memory_vault || @resident.create_memory_vault!
    end
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
    @vault.with_lock do
      raise Mnemodyne::Write::Conflict if @vault.erasure_requested_at? || @vault.suspended_at?
      @vault.update!(auto_preview_enabled: value)
    end
    show
  end

end
