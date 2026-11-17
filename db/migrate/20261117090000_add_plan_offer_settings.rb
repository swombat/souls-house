# #864 slice 3: the plan offer. An account switch (Colleagues), then a switch
# per resident, and the resident's own answer, which beats the owner's on.
class AddPlanOfferSettings < ActiveRecord::Migration[8.0]

  def change
    add_column :accounts, :plan_offer_enabled, :boolean, default: false, null: false
    add_column :agents, :plan_offer_enabled, :boolean, default: false, null: false
    add_column :agents, :plan_offer_asked_at, :datetime
    add_column :agents, :plan_offer_answer, :string
    add_column :agents, :plan_offer_answered_at, :datetime
  end

end
