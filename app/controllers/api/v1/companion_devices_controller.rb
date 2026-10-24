module Api
  module V1
    class CompanionDevicesController < BaseController

      before_action :require_human_actor!

      def update
        account = human_account!
        return head :forbidden unless human_membership!(account).admin?

        device = CompanionDevice.where(account: account).find(params[:id])
        return head :unprocessable_entity unless [ "pause", "resume", "revoke" ].include?(params[:control])

        device.with_lock do
          if params[:control] == "revoke"
            device.revoke!
          else
            device.update!(paused: params[:control] == "pause")
          end
          CompanionOperation.where(companion_device: device, state: CompanionOperation::ACTIVE_STATES)
            .update_all(state: "cancelled", outcome: "changed") unless params[:control] == "resume"
          unless params[:control] == "resume"
            control = params[:control]
            ActiveRecord.after_all_transactions_commit do
              CompanionChannel.broadcast_to(device, { type: control })
              ActionCable.server.remote_connections.where(current_user: nil, current_app_session: nil,
                current_companion_device: device).disconnect(reconnect: false)
            end
          end
          audit_human_action("companion_#{params[:control]}", device, account: account)
        end
        head :no_content
      end

    end
  end
end
