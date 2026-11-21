module Api
  module V1
    module Companion
      # Pairing with a code, the computer's side. Deliberately NOT BaseController:
      # no login exists yet. Opening a pairing grants nothing; only an owner or
      # admin approving its code on the Computers page does. After that, the poll
      # secret is the only way to collect the one-use enrollment token.
      class PairingsController < ActionController::API

        include ActionController::RateLimiting

        rate_limit to: 10, within: 10.minutes, only: :create,
          with: -> { render json: { error: "rate_limited" }, status: :too_many_requests }
        rate_limit to: 120, within: 1.minute, only: :claim,
          with: -> { render json: { error: "rate_limited" }, status: :too_many_requests }

        before_action { response.headers["Cache-Control"] = "no-store" }

        # Credentials are read from the request body only, never the query
        # string, so they can't land in access logs or error reports by URL.
        def create
          pairing, code, secret = CompanionPairing.open!(name: body[:name],
            device_request_id: body[:device_request_id], volumes: body[:volumes],
            kind: body[:kind], capabilities: body[:capabilities])
          render json: { id: pairing.to_param, code: code, poll_secret: secret,
            expires_at: pairing.expires_at.iso8601(3), poll_interval: 3 }, status: :created
        rescue CompanionPairing::Invalid, ActiveRecord::RecordInvalid => error
          render json: { error: error.message }, status: :unprocessable_entity
        end

        def claim
          state, payload = CompanionPairing.claim(params[:id], body[:poll_secret])
          case state
          when :pending then render json: { status: "pending" }, status: :accepted
          when :approved then render json: payload.merge("status" => "approved"), status: :ok
          when :expired then render json: { status: "expired" }, status: :gone
          else render json: { error: "Unknown pairing" }, status: :not_found
          end
        end

        private

        def body
          request.request_parameters.with_indifferent_access
        end

      end
    end
  end
end
