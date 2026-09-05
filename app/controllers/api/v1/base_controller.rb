module Api
  module V1
    class BaseController < ActionController::API

      include ApiAuthentication

      rescue_from Agent::RuntimeAvailability::Unavailable do |error|
        render json: { error: error.message, code: error.code }, status: :conflict
      end

      rescue_from ActiveRecord::RecordNotFound do
        render json: { error: "Not found" }, status: :not_found
      end

    end
  end
end
