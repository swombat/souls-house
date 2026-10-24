module Api
  module V1
    module Companion
      # Device credentials never enter ApiAuthentication or become human or
      # resident actors. This endpoint owns only ticket/credential exchange.
      class SessionsController < ActionController::API

        def create
          response.headers["Cache-Control"] = "no-store"
          bearer = request.headers["Authorization"]
          value = bearer.delete_prefix("Bearer ") if bearer.is_a?(String) && bearer.start_with?("Bearer ")
          result = CompanionDevice.create_session!(value, params[:request_id])
          render json: result, status: :created
        rescue CompanionDevice::Paused
          render json: { error: "Device paused", code: "paused" }, status: :locked
        rescue CompanionDevice::InvalidCredential
          render json: { error: "Invalid device credential" }, status: :unauthorized
        rescue CompanionDevice::RetryConflict
          render json: { error: "Retry the original request_id within 60 seconds, or use the current credential after that window" }, status: :conflict
        rescue ArgumentError => error
          render json: { error: error.message }, status: :unprocessable_entity
        end

      end
    end
  end
end
