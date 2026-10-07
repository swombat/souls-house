require "test_helper"

class UsersThemeHueTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:existing_user)
    sign_in @user
  end

  test "a person sets, sees and clears their own tint" do
    patch user_path, params: { user: { theme_hue: 355 } }
    assert_equal 355, @user.reload.theme_hue

    get edit_user_path, headers: { "X-Inertia" => "true", "X-Inertia-Version" => ViteRuby.digest }
    assert_equal 355, inertia_shared_props.dig("user", "theme_hue")

    get edit_user_path
    assert_select "html[style*='--tint-h: 355']"
    assert_select "html[style*='--tint-c: #{ApplicationHelper::TINT_CHROMA}']"

    patch user_path, params: { user: { theme_hue: "" } }
    assert_nil @user.reload.theme_hue
    get edit_user_path
    assert_select "html[style]", count: 0
  end

  test "out-of-range hues are rejected" do
    @user.profile.update!(theme_hue: 140)
    patch user_path, params: { user: { theme_hue: 400 } }
    assert_equal 140, @user.reload.theme_hue
  end

end
