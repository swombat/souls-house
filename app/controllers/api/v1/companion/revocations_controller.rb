module Api
  module V1
    module Companion
      # A credential can only revoke its own device here, even while paused.
      # Previously rotated credentials confer no authority, including here.
      class RevocationsController < ActionController::API

        def create
          response.headers["Cache-Control"] = "no-store"
          value = request.authorization.to_s.delete_prefix("Bearer ")
          return head :unauthorized unless CompanionDevice.credential?(value)

          digest = CompanionDevice.digest(value)
          device = CompanionDevice.find_by(credential_digest: digest)
          return head :unauthorized unless device

          device.with_lock do
            return head :unauthorized unless device.credential_digest == digest

            device.revoke!
            CompanionOperation.where(companion_device: device, state: CompanionOperation::ACTIVE_STATES)
              .update_all(state: "cancelled", outcome: "changed")
            ActiveRecord.after_all_transactions_commit do
              ActionCable.server.remote_connections.where(current_user: nil, current_app_session: nil,
                current_companion_device: device).disconnect(reconnect: false)
            end
          end
          head :no_content
        end

      end
    end
  end
end
