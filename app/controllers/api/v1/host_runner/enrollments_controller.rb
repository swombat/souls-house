module Api
  module V1
    module HostRunner
      class EnrollmentsController < BaseController

        # The request is signed with the key it asks to pin, which proves the
        # runner holds the private half. 202 means the server is not yet
        # confirmed by procurement; the token is not burned.
        def create
          public_key = payload["public_key"].to_s
          verify_signature!(public_key)
          result = enrollment.enroll!(
            token: payload["token"].to_s, public_key:, reported_server_id:, facts:
          )
          render json: { status: result.to_s }, status: result == :pending ? :accepted : :ok
        end

      end
    end
  end
end
