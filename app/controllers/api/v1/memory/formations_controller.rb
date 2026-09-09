class Api::V1::Memory::FormationsController < Api::V1::Memory::BaseController

  wrap_parameters false

  def create
    payload = params.permit!.to_h.except("controller", "action", "format")
    render json: write("formation:create", payload) {
      Mnemodyne::Formation.new(@vault, payload).call
    }, status: :created
  end

end
