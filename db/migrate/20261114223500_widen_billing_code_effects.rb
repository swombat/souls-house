# A billing code can now grant plans at cost for one size, or an account plan
# free, as well as plans at cost for every size. The model holds the list.
class WidenBillingCodeEffects < ActiveRecord::Migration[8.1]

  PATTERN = "effect ~ '^(at_cost(:[a-z_]+)?|plan:[a-z_]+)$'".freeze

  def up
    remove_check_constraint :billing_codes, name: "billing_codes_effect_known"
    add_check_constraint :billing_codes, PATTERN, name: "billing_codes_effect_known"
  end

  def down
    remove_check_constraint :billing_codes, name: "billing_codes_effect_known"
    add_check_constraint :billing_codes, "effect = 'at_cost'", name: "billing_codes_effect_known"
  end

end
