module Api
  module V1
    class CompanionDevicesController < BaseController

      before_action :require_human_actor!, except: :index

      # A resident's own view: the computers in its account that grant it
      # anything, and what each grants. Without this a resident had the
      # operations route but no way to learn a device's id (YEDPGJ, 20 Nov).
      # Only the calling resident's own entry is shown, never anyone else's.
      # A resident still named with nothing granted is listed on purpose:
      # CompanionOperation.permitted? allows drives for any named resident.
      def index
        agent = current_api_agent
        return head :forbidden unless agent

        computers = CompanionDevice.where(account_id: agent.account_id, revoked_at: nil).order(:id).filter_map do |device|
          mine = device.policy.fetch("residents", []).find { |r| r["id"] == agent.obfuscated_id }
          next unless mine

          {
            id: device.to_param,
            name: device.name,
            connected: device.connection_epoch.present?,
            paused: device.paused?,
            volumes: mine.fetch("volumes", []).map { |v| v.slice("volume", "access") },
            execute: mine["execute"] == true && !device.commands_off_locally?(agent.obfuscated_id),
            desktop: mine["desktop"] == true
          }
        end
        render json: { computers: computers }
      end

      def update
        account = human_account!
        human_membership!(account)
        device = CompanionDevice.where(account: account).find(params[:id])
        # Owners and admins, or the member who added this computer.
        return head :forbidden unless device.manageable_by?(current_api_user)
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
