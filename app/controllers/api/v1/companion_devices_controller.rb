module Api
  module V1
    class CompanionDevicesController < BaseController

      before_action :require_human_actor!

      def update
        account = human_account!
        return head :forbidden unless human_membership!(account).admin?

        device = CompanionDevice.where(account: account).find(params[:id])
        return change_authority(device, account) if params[:control] == "authority"
        return head :unprocessable_entity unless CompanionDevice::CONTROLS.include?(params[:control])

        device.apply_control!(params[:control]) do
          audit_human_action("companion_#{params[:control]}", device, account: account)
        end
        head :no_content
      end

      private

      # The owner's switch for one resident's execute/desktop on an enrolled
      # device, without re-enrolling. Both values are required, as booleans.
      def change_authority(device, account)
        flags = [ params[:execute], params[:desktop] ].map(&:to_s)
        return head :unprocessable_entity unless params[:resident_id].is_a?(String) && flags.all? { |f| %w[true false].include?(f) }

        # The model writes the audit row (actor, before, after, revision).
        changed = device.change_resident_authority!(resident_id: params[:resident_id], execute: flags[0] == "true",
          desktop: flags[1] == "true", actor: current_api_user)
        render json: { policy: device.reload.policy, grant_revision: device.grant_revision, changed: changed }
      rescue ArgumentError, CompanionEnrollmentGrant::InvalidPolicy
        head :unprocessable_entity
      end

    end
  end
end
