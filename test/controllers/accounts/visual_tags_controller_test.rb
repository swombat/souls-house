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
    assert_equal [ @tag.as_json.merge("conversation_count" => 0) ], inertia_shared_props["visual_tags"]
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

  test "the Pin tag can change colour and icon but not name, pinned flag, or existence" do
    pin = @account.visual_tags.create!(**VisualTag::PIN, pinned: true)
    chat = @account.chats.create!(title: "Pinned", model_id: "openrouter/auto", visual_tag: pin)

    patch account_visual_tag_path(@account, pin), params: { visual_tag: { colour: "rose", icon: "Heart", pinned: false } }
    assert_redirected_to account_interface_path(@account)
    assert_equal [ "Pin", "Heart", "rose", true ], pin.reload.values_at(:label, :icon, :colour, :pinned)

    patch account_visual_tag_path(@account, pin), params: { visual_tag: { label: "Top" } }
    assert_equal "Pin", pin.reload.label

    post account_visual_tags_path(@account), params: { visual_tag: { label: "Second", icon: "Heart", colour: "rose", pinned: true } }
    assert_equal [ pin ], @account.visual_tags.pinned.to_a

    assert_no_difference "VisualTag.count" do
      delete account_visual_tag_path(@account, pin)
    end
    assert_redirected_to account_interface_path(@account)
    assert_equal pin, chat.reload.visual_tag
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

    patch account_visual_tag_path(@account, @tag), params: { visual_tag: { colour: "unsafe" } }
    assert_redirected_to account_interface_path(@account)
    assert_equal "green", @tag.reload.colour
  end

  test "interface and chat picker share the same usage ranked account palette" do
    alpha = @account.visual_tags.create!(label: "alpha", icon: "Heart", colour: "rose")
    popular = @account.visual_tags.create!(label: "Zulu", icon: "Heart", colour: "rose")
    @account.chats.create!(title: "Alpha", model_id: "openrouter/auto", visual_tag: alpha)
    @account.chats.create!(title: "Popular", model_id: "openrouter/auto", visual_tag: popular)
    @account.chats.create!(title: "Archived", model_id: "openrouter/auto", visual_tag: popular).archive!
    @account.chats.create!(title: "Deleted", model_id: "openrouter/auto", visual_tag: @tag).discard!
    expected = [ popular.as_json.merge("conversation_count" => 2),
      alpha.as_json.merge("conversation_count" => 1), @tag.as_json.merge("conversation_count" => 0) ]
    headers = { "X-Inertia" => "true", "X-Inertia-Version" => ViteRuby.digest }

    get account_interface_path(@account), headers: headers
    assert_response :success
    assert_equal expected, inertia_shared_props["visual_tags"]
    get account_chats_path(@account), headers: headers
    assert_response :success
    assert_equal expected, inertia_shared_props["visual_tags"]
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
