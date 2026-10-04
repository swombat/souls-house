require "test_helper"

class Accounts::VisualTagsControllerTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:existing_user)
    @account = accounts(:team_account)
    @tag = @account.visual_tags.create!(label: "Plans", icon: "Compass", colour: "green")
    sign_in @user
  end

  test "confirmed ordinary member sees interface contract and edits account palette" do
    get account_interface_path(@account), headers: { "X-Inertia" => "true", "X-Inertia-Version" => ViteRuby.digest }
    assert_response :success
    assert_equal "accounts/interface", inertia_component
    assert_equal true, inertia_shared_props["can_manage"]
    assert_equal [ @tag.as_json ], inertia_shared_props["visual_tags"]
    assert_equal VisualTag::ICON_OPTIONS, inertia_shared_props["icon_options"]
    assert_equal VisualTag::COLOUR_OPTIONS, inertia_shared_props["colour_options"]

    assert_difference "VisualTag.count", 1 do
      post account_visual_tags_path(@account), params: {
        visual_tag: { label: "Care", icon: "Heart", colour: "rose", account_id: accounts(:other).id }
      }
    end
    assert_redirected_to account_interface_path(@account)
    assert_equal @account, VisualTag.last.account

    patch account_visual_tag_path(@account, @tag), params: { visual_tag: { label: "Revised", colour: "blue" } }
    assert_redirected_to account_interface_path(@account)
    assert_equal "Revised", @tag.reload.label
    assert_equal "blue", @tag.colour

    delete account_visual_tag_path(@account, @tag)
    assert_redirected_to account_interface_path(@account)
    assert_not VisualTag.exists?(@tag.id)
  end

  test "validation failures redirect with inertia errors and do not write" do
    assert_no_difference "VisualTag.count" do
      post account_visual_tags_path(@account), params: {
        visual_tag: { label: "", icon: "unsafe", colour: "unsafe" }
      }
    end
    assert_redirected_to account_interface_path(@account)
    follow_redirect!
    assert inertia_shared_props.fetch("errors").fetch("label").present?

    patch account_visual_tag_path(@account, @tag), params: { visual_tag: { colour: "red" } }
    assert_redirected_to account_interface_path(@account)
    assert_equal "green", @tag.reload.colour
  end

  test "foreign palette IDs cannot be edited or deleted" do
    foreign = accounts(:other).visual_tags.create!(label: "Foreign", icon: "Heart", colour: "rose")
    patch account_visual_tag_path(@account, foreign), params: { visual_tag: { label: "Stolen" } }
    assert_response :not_found
    delete account_visual_tag_path(@account, foreign)
    assert_response :not_found
    assert_equal "Foreign", foreign.reload.label
  end

  test "nonmembers cannot view or mutate another account palette" do
    other = accounts(:other)
    get account_interface_path(other)
    assert_response :not_found
    post account_visual_tags_path(other), params: { visual_tag: { label: "Care", icon: "Heart", colour: "rose" } }
    assert_response :not_found
    patch account_visual_tag_path(other, @tag), params: { visual_tag: { label: "No" } }
    assert_response :not_found
    delete account_visual_tag_path(other, @tag)
    assert_response :not_found
  end

  test "concurrent selection reports a retryable removal error without deleting the tag" do
    @tag.stub(:destroy!, -> { raise ActiveRecord::InvalidForeignKey }) do
      VisualTag.stub(:resolve_for, @tag) do
        delete account_visual_tag_path(@account, @tag)
      end
    end
    assert_redirected_to account_interface_path(@account)
    assert VisualTag.exists?(@tag.id)
    follow_redirect!
    assert_match "Please try again", inertia_shared_props.fetch("errors").fetch("visual_tag")
  end

  test "pending members have no interface access" do
    memberships(:team_member).update_columns(confirmed_at: nil)
    get account_interface_path(@account)
    assert_response :not_found
  end

  test "anonymous requests require sign in" do
    delete logout_path
    get account_interface_path(@account)
    assert_redirected_to login_path
  end

end
