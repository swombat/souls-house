class Admin::SettingsController < ApplicationController

  skip_before_action :set_current_account
  before_action :require_site_admin

  def show
    render inertia: "admin/settings", props: {
      setting: Setting.instance.as_json.merge(
        logo_url: Setting.instance.logo.attached? ? url_for(Setting.instance.logo) : nil
      ),
      follow_through_residents: follow_through_residents
    }
  end

  def update
    setting = Setting.instance

    setting.logo.purge if params[:setting]&.[](:remove_logo)

    saved = Setting.transaction do
      setting.update(setting_params).tap do |ok|
        update_follow_through_residents if ok && params[:setting]&.key?(:follow_through_resident_ids)
      end
    end

    if saved
      audit_with_changes("update_settings", setting, **@follow_through_changes.to_h)
      redirect_to admin_settings_path, notice: "Settings updated"
    else
      redirect_to admin_settings_path, inertia: { errors: setting.errors.to_hash }
    end
  end

  private

  def setting_params
    params.require(:setting).permit(
      :site_name,
      :allow_signups,
      :max_accounts,
      :allow_chats,
      :allow_agents,
      :show_usage_in_chat,
      :safeguard_conversations_enabled,
      :transcription_keyterms_enabled,
      :follow_through_scope,
      :logo
    )
  end

  # Every active resident, so the admin can pick who the follow-through check
  # covers when it is set to "selected".
  def follow_through_residents
    Agent.active.includes(:account).sort_by { |a| [ a.account&.name.to_s.downcase, a.name.to_s.downcase ] }.map do |agent|
      {
        id: agent.to_param,
        name: agent.name,
        account: agent.account&.name,
        icon: agent.icon,
        colour: agent.colour,
        paused: agent.paused?,
        follow_through: agent.follow_through?
      }
    end
  end

  # The form sends the full list of picked residents; anyone not in it is off.
  def update_follow_through_residents
    picked = Array(params[:setting][:follow_through_resident_ids]).compact_blank.filter_map do |param|
      Agent.find_by_obfuscated_id(param)&.id
    rescue StandardError
      nil
    end
    turned_on = Agent.active.where(id: picked, follow_through: false).pluck(:id)
    turned_off = Agent.active.where(follow_through: true).where.not(id: picked).pluck(:id)
    Agent.where(id: turned_on).update_all(follow_through: true, updated_at: Time.current)
    Agent.where(id: turned_off).update_all(follow_through: false, updated_at: Time.current)
    @follow_through_changes = {
      follow_through_on: Agent.where(id: turned_on).map(&:to_param),
      follow_through_off: Agent.where(id: turned_off).map(&:to_param)
    }.compact_blank
  end

  def require_site_admin
    redirect_to root_path unless Current.user&.is_site_admin?
  end

end
