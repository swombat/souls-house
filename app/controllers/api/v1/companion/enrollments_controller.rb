module Api
  module V1
    module Companion
      # Deliberately NOT BaseController: this is the sole public companion
      # endpoint. Its one-use enrollment token is its only authority.
      class EnrollmentsController < ActionController::API

        def create
          response.headers["Cache-Control"] = "no-store"
          result = CompanionEnrollmentGrant.enroll!(params[:enrollment_token], params[:device_request_id])
          return render json: { error: "Invalid enrollment" }, status: :unauthorized unless result

          render json: result.fetch(2), status: :created
        end

      end
    end
  end
end
