# The Computers page: each computer enrolled through the companion app,
# which residents it serves, and the owner's switches for them. Any confirmed
# member can see it; changing anything needs an account owner or admin, the
# same rule as PATCH /api/v1/companion_devices/:id.
class Accounts::CompanionDevicesController < ApplicationController

  before_action :set_account
  before_action :require_admin!, only: :update

  def index
    devices = CompanionDevice.where(account: @account).where(revoked_at: nil).order(:created_at).to_a
    agents = @account.agents.where(id: devices.flat_map { |d| resident_ids(d) }.uniq).index_by(&:to_param)
    render inertia: "accounts/computers", props: {
      account: @account.as_json,
      can_manage: admin?,
      devices: devices.map { |device| device_json(device, agents) },
      warnings: {
        execute: CompanionEnrollmentGrant::EXECUTE_WARNING,
        desktop: CompanionEnrollmentGrant::DESKTOP_WARNING
      }
    }
  end

  def update
    device = CompanionDevice.where(account: @account).where(revoked_at: nil).find(params[:id])
    if params[:control] == "authority"
      change_authority(device)
    elsif CompanionDevice::CONTROLS.include?(params[:control])
      control = params[:control]
      device.apply_control!(control) { audit("companion_#{control}", device) }
      redirect_to account_companion_devices_path(@account), notice: control_notice(device, control)
    else
      redirect_to account_companion_devices_path(@account), alert: "Unknown change"
    end
  end

  private

  def change_authority(device)
    # One switch per request: the page names the permission it changes and
    # never sends the other, so a stale page can't put back a permission
    # that was turned off elsewhere. The model reads the other under its lock.
    permission = params[:permission].to_s
    value = params[:value].to_s
    unless params[:resident_id].is_a?(String) && %w[execute desktop].include?(permission) && %w[true false].include?(value)
      return redirect_to account_companion_devices_path(@account), alert: "That change wasn't understood"
    end

    # The model writes the audit row (actor, before, after, revision).
    changed = device.change_resident_authority!(resident_id: params[:resident_id],
      permission.to_sym => value == "true", actor: Current.user)
    notice = changed ? "Saved. Work already running on #{device.name} was stopped." : "Nothing changed"
    redirect_to account_companion_devices_path(@account), notice: notice
  rescue ArgumentError, CompanionEnrollmentGrant::InvalidPolicy
    redirect_to account_companion_devices_path(@account), alert: "That change wasn't possible"
  end

  def device_json(device, agents)
    {
      id: device.to_param,
      name: device.name,
      paused: device.paused,
      connected: device.connection_epoch.present?,
      enrolled_at: device.created_at,
      residents: device.policy.fetch("residents").map do |resident|
        agent = agents[resident["id"]]
        {
          id: resident["id"],
          name: agent&.name || "Resident no longer here",
          execute: resident["execute"] == true,
          desktop: resident["desktop"] == true,
          volumes: resident.fetch("volumes")
        }
      end
    }
  end

  def resident_ids(device)
    device.policy.fetch("residents").map { |resident| Agent.decode_id(resident["id"]) }
  rescue Hashids::InputError
    []
  end

  def control_notice(device, control)
    case control
    when "pause" then "#{device.name} is paused. Nothing will run there until you resume it."
    when "resume" then "#{device.name} is running again."
    else "#{device.name} was removed. It can't connect again without a new enrollment."
    end
  end

  def admin?
    return @admin if defined?(@admin)

    @admin = Current.user&.site_admin ||
      Current.user&.confirmed_memberships&.find_by(account: @account)&.admin? || false
  end

  def require_admin!
    return if admin?

    redirect_to account_companion_devices_path(@account), alert: "Only an owner or admin of this account can change computers"
  end

  def set_account
    @account = find_current_user_account!(params[:account_id])
    Current.account = @account
  end

  def current_account
    @account || super
  end

end
