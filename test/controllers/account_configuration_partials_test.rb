require "test_helper"

class AccountConfigurationPartialsTest < ActionDispatch::IntegrationTest

  setup do
    @account = accounts(:team_account)
    @member = users(:existing_user)
    sign_in @member
  end

  test "navbar and newly mapped General partials do not build unrequested members" do
    controller = AccountsController.new
    AccountsController.stub :new, controller do
      controller.stub :account_members_json, -> { flunk "partial built unrequested members" } do
        [
          "accounts,expired_subscriptions,account,is_account_admin",
          "account,is_account_admin",
          "can_be_personal,can_manage,resident_handoff_cap"
        ].each do |props|
          get account_path(@account), headers: partial("accounts/show", props)
          assert_response :success
          result = response.parsed_body.fetch("props")
          assert_not result.key?("members")
          props.split(",").each { |prop| assert result.key?(prop), "missing #{prop}" }
        end
      end
    end
  end

  test "requested members are evaluated and pending invitations update conversion eligibility" do
    account = accounts(:team_single_user)
    sign_in users(:user_1)
    get account_path(account), headers: partial("accounts/show", "members,can_be_personal")
    assert_response :success
    assert response.parsed_body.dig("props", "can_be_personal")
    assert_equal 1, response.parsed_body.dig("props", "members").length

    Membership.create!(account:, user: users(:confirmed_user), role: "member", invited_by: users(:user_1))
    get account_path(account), headers: partial("accounts/show", "members,can_be_personal")
    assert_response :success
    assert_not response.parsed_body.dig("props", "can_be_personal")
    assert_equal 1, response.parsed_body.dig("props", "members").count { |member| member["invitation_pending"] }
  end

  test "confirmed owner admin and ordinary member retain the existing manageability policy" do
    membership = memberships(:team_member)
    %w[owner admin member].each do |role|
      membership.update!(role:)
      [
        [ account_path(@account), "accounts/show" ],
        [ account_interface_path(@account), "accounts/interface" ],
        [ account_rooms_path(@account), "accounts/rooms" ]
      ].each do |path, component|
        get path, headers: partial(component, "account,is_account_admin,can_manage")
        assert_response :success
        props = response.parsed_body.fetch("props")
        assert_equal @account.to_param, props.dig("account", "id")
        assert_equal true, props.fetch("is_account_admin")
        assert_equal true, props.fetch("can_manage")
      end
      patch account_path(@account), params: { account: { resident_handoff_cap: role.length } }
      assert_redirected_to @account
      assert_equal role.length, @account.reload.resident_handoff_cap
    end
  end

  test "presentation partials return current name logo and handoff values" do
    @account.update!(name: "Current settings", logo_colour: "teal", resident_handoff_cap: 11)
    [
      [ account_path(@account), "accounts/show" ],
      [ account_interface_path(@account), "accounts/interface" ],
      [ account_rooms_path(@account), "accounts/rooms" ]
    ].each do |path, component|
      get path, headers: partial(component, "account,is_account_admin,can_manage,resident_handoff_cap")
      assert_response :success
      props = response.parsed_body.fetch("props")
      assert_equal "Current settings", props.dig("account", "name")
      assert_equal "teal", props.dig("account", "logo_colour")
      assert_equal true, props.fetch("can_manage")
      assert_equal true, props.fetch("is_account_admin")
      assert_equal 11, props.fetch("resident_handoff_cap") if component == "accounts/show"
      assert_not props.key?("members")
    end
  end

  test "unconfirmation and removal reject refreshed reads and writes rather than inventing revoked props" do
    membership = memberships(:team_member)
    membership.update!(confirmed_at: nil)
    assert_inaccessible
    membership.destroy!
    assert_inaccessible
    assert_equal 6, @account.reload.resident_handoff_cap
  end

  test "foreign account partials and writes remain inaccessible" do
    @account = accounts(:other)
    assert_inaccessible
  end

  private

  def assert_inaccessible
    [
      [ account_path(@account), "accounts/show" ],
      [ account_interface_path(@account), "accounts/interface" ],
      [ account_rooms_path(@account), "accounts/rooms" ]
    ].each do |path, component|
      get path, headers: partial(component, "account,is_account_admin,can_manage")
      assert_response :not_found
    end
    patch account_path(@account), params: { account: { resident_handoff_cap: 20 } }
    assert_response :not_found
    patch account_interface_path(@account), params: { account: { logo_colour: "teal" } }
    assert_response :not_found
    assert_no_difference "Room.count" do
      post account_rooms_path(@account), params: { room: { name: "Forbidden" } }
      assert_response :not_found
    end
  end

  def partial(component, props)
    {
      "X-Inertia" => "true", "X-Inertia-Version" => ViteRuby.digest,
      "X-Inertia-Partial-Component" => component, "X-Inertia-Partial-Data" => props
    }
  end

end
