class Admin::SettingsController < ApplicationController

  skip_before_action :set_current_account
  before_action :require_site_admin

  def show
    render inertia: "admin/settings", props: {
      setting: Setting.instance.as_json.merge(
        logo_url: Setting.instance.logo.attached? ? url_for(Setting.instance.logo) : nil
      )
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
      :allow_chats,
      :allow_agents,
      :show_usage_in_chat,
      :safeguard_owner_notice_threshold,
      :logo
    )
  end

  def require_site_admin
    redirect_to root_path unless Current.user&.is_site_admin?
  end

end
