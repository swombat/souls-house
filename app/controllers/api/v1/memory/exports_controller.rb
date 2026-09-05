class Api::V1::Memory::ExportsController < Api::V1::Memory::BaseController

  rescue_from Mnemodyne::Checkpoint::Invalid do
    render json: { error: "Checkpoint unavailable: resident identity or graph is invalid" }, status: :unprocessable_entity
  end

  def show
    envelope = Mnemodyne::Checkpoint.export(@vault)
    render json: envelope.merge("export_receipt" => Mnemodyne::Erasure.export_receipt(@vault, envelope))
  end

end
