require "test_helper"

# Daniel (2026-10-26, JOyyke): the UI shows in red what only site admins can see.
# These are the server facts the red depends on.
class SiteAdminOnlyMarkingTest < ActionDispatch::IntegrationTest

  test "viewing_as_site_admin is true only for a site admin outside the account" do
    admin = users(:site_admin_user)
    sign_in admin
    get account_path(accounts(:site_admin_account))
    assert_equal false, inertia_shared_props["viewing_as_site_admin"]

    @inertia_props = nil
    get account_path(accounts(:team_account))
    assert_equal true, inertia_shared_props["viewing_as_site_admin"]
    # is_account_admin includes site admins, so it cannot tell the two apart.
    assert_equal true, inertia_shared_props["is_account_admin"]
  end

  test "a member is never viewing as site admin" do
    sign_in users(:user_1)
    get account_path(accounts(:team_account))
    assert_equal false, inertia_shared_props["viewing_as_site_admin"]
  end

  test "site_admin_page marks every Admin:: page, including notices which renders notices/index" do
    sign_in users(:site_admin_user)
    get admin_notices_path
    assert_equal "notices/index", inertia_component
    assert_equal true, inertia_shared_props["site_admin_page"]

    @inertia_props = nil
    get account_path(accounts(:site_admin_account))
    assert_equal false, inertia_shared_props["site_admin_page"]
  end

  test "a message's edit and delete are admin-only only when a site admin is not its author" do
    author = users(:user_1)
    agent = agents(:research_assistant)
    chat = agent.account.chats.create!(title: "Red controls", model_id: "openrouter/auto", manual_responses: true, agents: [ agent ])
    message = chat.messages.create!(role: "user", user: author, content: "Mine", suppress_automatic_dispatch: true)

    Current.session = Session.new(user: author)
    assert message.editable
    assert_equal false, message.as_json["controls_admin_only"]

    Current.session = Session.new(user: users(:site_admin_user))
    assert message.editable
    assert_equal true, message.as_json["controls_admin_only"]
  ensure
    Current.reset
  end

end
