class Admin::SettingsController < ApplicationController

  skip_before_action :set_current_account
  before_action :require_site_admin

  def show
    render inertia: "admin/settings", props: {
      setting: Setting.instance.as_json.merge(
        logo_url: Setting.instance.logo.attached? ? url_for(Setting.instance.logo) : nil
      ),
      follow_through_residents: follow_through_residents(Setting.instance)
    }
  end

  def update
    setting = Setting.instance

    setting.logo.purge if params[:setting]&.[](:remove_logo)

    if setting.update(setting_params)
      audit_with_changes("update_settings", setting)
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
      :follow_through_residents,
      :logo
    )
  end

  # Resolves the ids in the follow-through setting so the admin can see who
  # they've switched on, and which ids match no resident.
  def follow_through_residents(setting)
    setting.follow_through_resident_ids.map do |param|
      agent = begin
        Agent.find_by_obfuscated_id(param)
      rescue StandardError
        nil
      end
      agent = nil if agent && agent.to_param != param
      { id: param, name: agent&.name, account: agent&.account&.name }
    end
  end

  def require_site_admin
    redirect_to root_path unless Current.user&.is_site_admin?
  end

end
