class Accounts::InterfacesController < ApplicationController

  before_action :require_account_manager!, only: :update

  def show
    render inertia: "accounts/interface", props: {
      account: current_account,
      can_manage: current_account.manageable_by?(Current.user),
      icon_options: VisualTag::ICON_OPTIONS,
      colour_options: VisualTag::COLOUR_OPTIONS,
      logo_colour_options: Account::LOGO_COLOURS
    }
  end

  # Only the logo colour is editable here; the account's other settings keep their own forms.
  def update
    current_account.update!(logo_colour: params.expect(account: [ :logo_colour ])[:logo_colour].presence)
    audit_with_changes(:update_account_logo_colour, current_account)
    redirect_to account_interface_path(current_account), notice: "Logo colour updated"
  rescue ActiveRecord::RecordInvalid => error
    redirect_to account_interface_path(current_account), inertia: { errors: error.record.errors.to_hash }
  end

end
