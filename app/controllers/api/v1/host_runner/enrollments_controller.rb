module Api
  module V1
    module HostRunner
      class EnrollmentsController < BaseController

        # The request is signed with the key it asks to pin, which proves the
        # runner holds the private half. 202 means the server is not yet
        # confirmed by procurement; the token is not burned.
        def create
          public_key = payload["public_key"].to_s
          token = payload["token"].to_s
          nonce = verify_signature!(public_key)
          # A signature by a caller-chosen key proves possession, not
          # authority. The bound one-time token is the authority, so it is
          # checked before anything is written.
          enrollment.authenticate_token!(token)
          record_nonce!(nonce)
          result = enrollment.enroll!(token:, public_key:, reported_server_id:, facts:)
          render json: { status: result.to_s }, status: result == :pending ? :accepted : :ok
        end

      end
    end
  end
end
