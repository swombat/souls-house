class AddThemeHueAndLogoColour < ActiveRecord::Migration[8.1]

  def change
    # Personal: one hue (0-359) that tints the neutral palette. Null = untinted default.
    add_column :profiles, :theme_hue, :integer
    # Account: a named colour from Account::LOGO_COLOURS for the dot in the logo. Null = default coral.
    add_column :accounts, :logo_colour, :string
  end

end
