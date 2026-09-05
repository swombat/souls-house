class Api::V1::Memory::ExportsController < Api::V1::Memory::BaseController

  rescue_from Mnemodyne::Checkpoint::Invalid do
    render json: { error: "Checkpoint unavailable: resident identity or graph is invalid" }, status: :unprocessable_entity
  end

  def show
    render json: Mnemodyne::Checkpoint.export(@vault)
  end

end
