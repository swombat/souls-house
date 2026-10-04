class Accounts::InterfacesController < ApplicationController

  def show
    render inertia: "accounts/interface", props: {
      account: current_account,
      can_manage: current_account.manageable_by?(Current.user),
      visual_tags: current_account.visual_tags.palette_order.map(&:as_json),
      icon_options: VisualTag::ICON_OPTIONS,
      colour_options: VisualTag::COLOUR_OPTIONS
    }
  end

end
