module Api
  module V1
    module HostRunner
      class HeartbeatsController < BaseController

        def create
          # Same answer as an unknown runner, so an unauthenticated caller learns
          # nothing about enrollment state.
          raise RunnerSignature::Invalid.new(:unknown_runner) unless enrollment.enrolled?

          nonce = verify_signature!(enrollment.public_key)
          enrollment.heartbeat!(reported_server_id:, facts:, nonce:)
          Backup::VmResident.release_after_recovery!(enrollment:)
          RunnerBundle.offer!(enrollment)
          KernelReboot.observe!(enrollment)
          KernelReboot.offer!(enrollment)
          # A Boat runner stamps the epoch it is told here on its next
          # heartbeat; that is how a wake is known to have reached it.
          placement = AgentPlacement.find_by(id: enrollment.agent_placement_id)
          BoatPower.observe_heartbeat!(placement, facts)
          render json: { status: "ok" }.merge(BoatPower.heartbeat_answer(placement&.reload))
        end

      end
    end
  end
end
