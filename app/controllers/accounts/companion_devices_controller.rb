# The Computers page: each computer enrolled through the companion app,
# which residents it serves, and the switches for them. Any confirmed member
# can see it; changing a computer needs an account owner or admin, or the
# member who added that computer (CompanionDevice#manageable_by?), the same
# rule as PATCH /api/v1/companion_devices/:id.
class Accounts::CompanionDevicesController < ApplicationController

  before_action :set_account
  before_action :set_device, :require_device_manager!, only: :update

  def index
    devices = CompanionDevice.where(account: @account).where(revoked_at: nil).includes(:companion_enrollment_grant)
      .order(:created_at).to_a
    agents = @account.agents.where(id: devices.flat_map { |d| resident_ids(d) }.uniq).index_by(&:to_param)
    activity = activity_for(devices)
    render inertia: "accounts/computers", props: {
      account: @account.as_json,
      can_manage: admin?,
      can_add: member?,
      devices: devices.map { |device| device_json(device, agents, activity) },
      warnings: {
        execute: CompanionEnrollmentGrant::EXECUTE_WARNING,
        desktop: CompanionEnrollmentGrant::DESKTOP_WARNING,
        write: CompanionEnrollmentGrant::WRITE_WARNING
      }
    }
  end

  def update
    device = @device
    if params[:control] == "capture"
      change_capture(device)
    elsif params[:control] == "authority"
      change_authority(device)
    elsif params[:control] == "volume"
      change_volume(device)
    elsif params[:control] == "conversation"
      change_conversation(device)
    elsif CompanionDevice::CONTROLS.include?(params[:control])
      control = params[:control]
      device.apply_control!(control) { audit("companion_#{control}", device) }
      redirect_to account_companion_devices_path(@account), notice: control_notice(device, control)
    else
      redirect_to account_companion_devices_path(@account), alert: "Unknown change"
    end
  end

  private

  # The stone's conversation (eKmnrJ): pick one the owner can see, or start
  # a new one, private if asked. Only the owner; the model enforces it too.
  def change_conversation(device)
    return redirect_to(account_companion_devices_path(@account), alert: "Only the stone's owner can change its conversation") unless device.owned_by?(Current.user)

    if params[:new_conversation] == "true"
      chat = device.start_pocket_conversation!(title: params[:title].to_s.strip.first(200),
        private: params[:private] == "true", actor: Current.user)
      notice = chat.private? ? "The stone now talks in a new private conversation" : "The stone now talks in a new conversation"
    else
      chat = visible_chats.kept.find_by(id: Chat.decode_id(params[:chat_id].to_s))
      device.retarget_pocket!(chat: chat, actor: Current.user)
      notice = "The stone now talks in #{chat.title_or_default}"
    end
    audit("companion_conversation", device, chat_id: chat.to_param)
    redirect_to account_companion_devices_path(@account), notice: notice
  rescue CompanionDevice::Pocket::Refused => e
    message = e.code == "resident_not_in_conversation" ? "That conversation doesn't have the stone's resident in it" : "That conversation isn't available"
    redirect_to account_companion_devices_path(@account), alert: message
  rescue Hashids::InputError
    redirect_to account_companion_devices_path(@account), alert: "That conversation isn't available"
  end

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

  # A pocket device's microphone or camera. Only its owner turns one on; the
  # owner or a manager turns one off (CompanionDevice::Pocket).
  def change_capture(device)
    capability = params[:capability].to_s
    value = params[:value].to_s
    unless CompanionPairing::CAPABILITIES.include?(capability) && %w[true false].include?(value)
      return redirect_to account_companion_devices_path(@account), alert: "That change wasn't understood"
    end

    changed = device.change_capture!(capability: capability, enabled: value == "true", actor: Current.user)
    notice = if !changed then "Nothing changed"
    elsif value == "true" then "#{device.name} can use its #{capability == "mic" ? "microphone" : "camera"} when you press to capture."
    else "#{device.name}'s #{capability == "mic" ? "microphone" : "camera"} is off."
    end
    redirect_to account_companion_devices_path(@account), notice: notice
  rescue CompanionDevice::Pocket::NotOwner
    redirect_to account_companion_devices_path(@account), alert: "Only the person who owns #{device.name} can turn that on"
  rescue ArgumentError
    redirect_to account_companion_devices_path(@account), alert: "That change wasn't possible"
  end

  ACTIVITY_DAYS = 7

  # Jobs each computer ran, per day for the last week, how many of them
  # failed, and when the last one was asked for. Counts only: the page never
  # shows what a job was.
  def activity_for(devices)
    ids = devices.map(&:id)
    return {} if ids.empty?

    first_day = (ACTIVITY_DAYS - 1).days.ago.utc.beginning_of_day
    daily = CompanionOperation.where(companion_device_id: ids, created_at: first_day..)
      .group(:companion_device_id, Arel.sql("date_trunc('day', created_at)"), :state).count
    last = CompanionOperation.where(companion_device_id: ids).group(:companion_device_id).maximum(:created_at)
    days = (0...ACTIVITY_DAYS).map { |offset| (first_day + offset.days).to_date }

    ids.index_with do |id|
      per_day = Hash.new(0)
      failed = 0
      daily.each do |(device_id, day, state), count|
        next unless device_id == id

        per_day[day.to_date] += count
        failed += count if %w[failed timed_out lost].include?(state)
      end
      { days: days.map { |day| { date: day.iso8601, jobs: per_day[day] } }, failed: failed, last_job_at: last[id] }
    end
  end

  # One folder for one resident per request: off, read or write. The model
  # keeps every other folder and both switches as stored, and refuses to
  # widen past what the computer last reported it allows.
  def change_volume(device)
    access = params[:access].to_s
    unless params[:resident_id].is_a?(String) && params[:volume].is_a?(String) &&
        CompanionDevice::ACCESS_RANK.key?(access)
      return redirect_to account_companion_devices_path(@account), alert: "That change wasn't understood"
    end

    changed = device.change_resident_volume!(resident_id: params[:resident_id], volume: params[:volume],
      access: access, actor: Current.user)
    notice = changed ? "Saved. Work already running on #{device.name} was stopped." : "Nothing changed"
    redirect_to account_companion_devices_path(@account), notice: notice
  rescue CompanionDevice::AboveCeiling
    redirect_to account_companion_devices_path(@account),
      alert: "#{device.name} doesn't allow that. Widen it on the computer first, then try again."
  rescue ArgumentError, CompanionEnrollmentGrant::InvalidPolicy
    redirect_to account_companion_devices_path(@account), alert: "That change wasn't possible"
  end

  def device_json(device, agents, activity)
    {
      id: device.to_param,
      name: device.name,
      kind: device.kind,
      pocket: (pocket_json(device) if device.pocket?),
      paused: device.paused,
      connected: device.connection_epoch.present?,
      commands_off_locally: device.commands_off_locally?,
      enrolled_at: device.created_at,
      activity: activity.fetch(device.id, { days: [], failed: 0, last_job_at: nil }),
      can_manage: manages?(device),
      ceiling: (ceiling_json(device) if manages?(device)),
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

  def pocket_json(device)
    owner = device.companion_enrollment_grant.created_by_user
    {
      owner_name: owner && ResidentFacingName.for(owner),
      owned_by_you: device.owned_by?(Current.user),
      capabilities: device.offered_capabilities,
      mic: device.mic_enabled,
      camera: device.camera_enabled,
      # A private conversation's name and link only for someone in it.
      chat_id: device.chat&.visible_to?(Current.user) ? device.chat.to_param : nil,
      chat_title: if device.chat.nil? then nil
                  elsif device.chat.visible_to?(Current.user) then device.chat.title_or_default
                  else "A private conversation"
                  end,
      chat_private: device.chat&.private? || false,
      conversation_choices: device.owned_by?(Current.user) ? pocket_conversation_choices(device) : []
    }
  end

  # Where the owner could point the stone: their visible conversations that
  # seat its resident, most recent first.
  def pocket_conversation_choices(device)
    agent_id = Agent.decode_id(device.bound_resident_id.to_s)
    visible_chats.kept.active.joins(:chat_agents).where(chat_agents: { agent_id: agent_id })
      .latest.limit(30).map { |chat| { id: chat.to_param, title: chat.title_or_default, private: chat.private? } }
  rescue Hashids::InputError
    []
  end

  def resident_ids(device)
    device.policy.fetch("residents").map { |resident| Agent.decode_id(resident["id"]) }
  rescue Hashids::InputError
    []
  end

  # What the computer last said its own ceiling allows, only for those who
  # may change the computer. nil means it has never reported (an older companion): the page then
  # leaves folders read-only. `current` is false once that connection is gone.
  def ceiling_json(device)
    return unless device.reported_ceiling

    {
      reported_at: device.ceiling_reported_at,
      current: device.connection_epoch.present? && device.ceiling_epoch == device.connection_epoch,
      residents: device.reported_ceiling.fetch("residents").to_h { |r| [ r["id"], r["volumes"] ] }
    }
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

  def member?
    Current.user&.site_admin || Current.user&.confirmed_memberships&.exists?(account: @account) || false
  end

  def manages?(device)
    admin? || device.manageable_by?(Current.user)
  end

  def set_device
    @device = CompanionDevice.where(account: @account).where(revoked_at: nil).find(params[:id])
  end

  def require_device_manager!
    return if manages?(@device)

    redirect_to account_companion_devices_path(@account),
      alert: "Only an owner or admin of this account, or whoever added this computer, can change it"
  end

  def set_account
    @account = find_current_user_account!(params[:account_id])
    Current.account = @account
  end

  def current_account
    @account || super
  end

end
