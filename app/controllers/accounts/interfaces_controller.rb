class Accounts::InterfacesController < ApplicationController

  before_action :require_account_manager!, only: :update

  # The Interface tab became Tags (visual tags) and the logo colour moved to
  # General; the old address still lands somewhere sensible.
  def show
    redirect_to account_tags_path(current_account)
  end

  # Only the logo colour is editable here; the account's other settings keep their own forms.
  def update
    current_account.update!(logo_colour: params.expect(account: [ :logo_colour ])[:logo_colour].presence)
    audit_with_changes(:update_account_logo_colour, current_account)
    redirect_to account_path(current_account), notice: "Logo colour updated"
  rescue ActiveRecord::RecordInvalid => error
    redirect_to account_path(current_account), inertia: { errors: error.record.errors.to_hash }
  end

end
