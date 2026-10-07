require "test_helper"

class Accounts::InterfacesControllerTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:existing_user)
    @account = accounts(:team_account)
    sign_in @user
  end

  test "interface offers the curated logo colours" do
    get account_interface_path(@account), headers: { "X-Inertia" => "true", "X-Inertia-Version" => ViteRuby.digest }
    assert_response :success
    assert_equal Account::LOGO_COLOURS, inertia_shared_props["logo_colour_options"]
  end

  test "a member sets and clears the account logo colour" do
    patch account_interface_path(@account), params: { account: { logo_colour: "teal" } }
    assert_redirected_to account_interface_path(@account)
    assert_equal "teal", @account.reload.logo_colour

    patch account_interface_path(@account), params: { account: { logo_colour: "" } }
    assert_redirected_to account_interface_path(@account)
    assert_nil @account.reload.logo_colour
  end

  test "colours outside the curated list are rejected without writing" do
    @account.update!(logo_colour: "plum")
    patch account_interface_path(@account), params: { account: { logo_colour: "hotpink" } }
    assert_redirected_to account_interface_path(@account)
    follow_redirect!
    assert inertia_shared_props.fetch("errors").fetch("logo_colour").present?
    assert_equal "plum", @account.reload.logo_colour
  end

  test "only the logo colour is writable through this form" do
    patch account_interface_path(@account), params: { account: { logo_colour: "sky", name: "Renamed" } }
    assert_equal "sky", @account.reload.logo_colour
    assert_not_equal "Renamed", @account.name
  end

  test "a malformed parameter envelope is a bad request, not a crash" do
    patch account_interface_path(@account), params: { account: "teal" }
    assert_response :bad_request
    assert_nil @account.reload.logo_colour
  end

  test "nonmembers cannot change another account's logo colour" do
    other = accounts(:other)
    patch account_interface_path(other), params: { account: { logo_colour: "teal" } }
    assert_response :not_found
    assert_nil other.reload.logo_colour
  end

  test "the account colour is rendered on html for first paint" do
    @account.update!(logo_colour: "moss")
    get account_interface_path(@account)
    assert_response :success
    assert_select "html[data-account-colour=moss]"
  end

end
