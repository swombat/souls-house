module Api
  module V1
    module HostRunner
      class HeartbeatsController < BaseController

        def create
          # Same answer as an unknown runner, so an unauthenticated caller learns
          # nothing about enrollment state.
          raise RunnerSignature::Invalid.new(:unknown_runner) unless enrollment.enrolled?

          record_nonce!(verify_signature!(enrollment.public_key))
          enrollment.heartbeat!(reported_server_id:, facts:)
          render json: { status: "ok" }
        end

      end
    end
  end
end
