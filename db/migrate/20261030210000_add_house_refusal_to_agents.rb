# The house gateway's last allowance refusal of a resident: the code it
# refused with and when. A failed run whose window holds the mark can say
# "its house allowance is used up" from a field the house wrote itself,
# instead of guessing from error text.
class AddHouseRefusalToAgents < ActiveRecord::Migration[8.1]

  def change
    add_column :agents, :house_refusal_code, :string
    add_column :agents, :house_refused_at, :datetime
  end

end
