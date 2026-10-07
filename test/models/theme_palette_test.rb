require "test_helper"

# The palette lives in three places (Ruby validation, CSS selectors, JS constants);
# these checks keep them from drifting apart.
class ThemePaletteTest < ActiveSupport::TestCase

  CSS = Rails.root.join("app/frontend/entrypoints/application.css").read
  THEME_JS = Rails.root.join("app/frontend/lib/theme.js").read

  test "theme hue accepts whole degrees 0-359 or nothing" do
    profile = users(:existing_user).profile
    [ nil, 0, 180, 359 ].each do |hue|
      profile.theme_hue = hue
      assert profile.valid?, "expected #{hue.inspect} to be valid"
    end
    [ -1, 360, 12.5 ].each do |hue|
      profile.theme_hue = hue
      assert_not profile.valid?, "expected #{hue.inspect} to be invalid"
    end
  end

  test "account logo colour must be one of the curated names" do
    account = accounts(:team_account)
    account.logo_colour = nil
    assert account.valid?
    Account::LOGO_COLOURS.each do |colour|
      account.logo_colour = colour
      assert account.valid?, colour
    end
    account.logo_colour = "hotpink"
    assert_not account.valid?
  end

  test "every logo colour has a light and a dark value in the stylesheet" do
    light = CSS.scan(/^\[data-account-colour=["'](\w+)["']\] \{/).flatten
    dark = CSS.scan(/^\.dark \[data-account-colour=["'](\w+)["']\] \{/).flatten
    assert_equal Account::LOGO_COLOURS.sort, light.sort
    assert_equal Account::LOGO_COLOURS.sort, dark.sort
  end

  test "server and client agree on the tint strength" do
    assert_includes THEME_JS, "export const TINT_CHROMA = #{ApplicationHelper::TINT_CHROMA};"
  end

  test "the logo dot reads the account colour with the original coral as fallback" do
    svg = Rails.root.join("app/assets/images/souls-house-logo.svg").read
    assert_includes svg, "fill: var(--account-dot, #f15d61)"
  end

end
