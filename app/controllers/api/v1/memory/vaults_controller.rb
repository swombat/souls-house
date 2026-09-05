class Api::V1::Memory::VaultsController < Api::V1::Memory::BaseController

  skip_before_action :require_vault!, only: [ :show, :create ]

  def show
    vault = @resident.memory_vault
    render json: { enabled: vault.present?, suspended: vault&.suspended_at?,
      auto_preview_enabled: vault&.auto_preview_enabled? || false,
      nodes: vault&.nodes&.count || 0, edges: vault&.edges&.count || 0 }
  end

  def create
    @resident.with_lock do
      @vault = @resident.memory_vault || @resident.create_memory_vault!
    end
    show
  end

  def update
    value = params.require(:auto_preview_enabled)
    raise ArgumentError unless [ true, false ].include?(value)
    @vault.update!(auto_preview_enabled: value)
    show
  end

end
