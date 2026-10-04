require "test_helper"

class Chats::VisualTagsControllerTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:existing_user)
    @account = accounts(:team_account)
    @tag = @account.visual_tags.create!(label: "Care", icon: "Heart", colour: "rose")
    @chat = @account.chats.create!(title: "Keep title", model_id: "openrouter/auto")
    sign_in @user
  end

  test "member sets and clears tag while staying on the current thread" do
    current_chat = @account.chats.create!(title: "Currently open", model_id: "openrouter/auto")
    referer = account_chat_url(@account, current_chat)
    patch account_chat_visual_tag_path(@account, @chat), params: { visual_tag_id: @tag.to_param },
      headers: { "HTTP_REFERER" => referer }
    assert_redirected_to referer
    assert_equal @tag, @chat.reload.visual_tag
    assert_equal "Keep title", @chat.title

    patch account_chat_visual_tag_path(@account, @chat), params: { visual_tag_id: nil }, as: :json
    assert_redirected_to account_chat_path(@account, @chat)
    assert_nil @chat.reload.visual_tag
  end

  test "missing selection is not mistaken for a clear" do
    @chat.update!(visual_tag: @tag)
    patch account_chat_visual_tag_path(@account, @chat), params: {}, as: :json
    assert_redirected_to account_chat_path(@account, @chat)
    assert_equal @tag, @chat.reload.visual_tag
  end

  test "concurrent tag deletion is reported as a retryable selection error" do
    VisualTag.stub(:resolve_for, ->(*) { raise ActiveRecord::InvalidForeignKey }) do
      patch account_chat_visual_tag_path(@account, @chat),
        params: { visual_tag_id: @tag.to_param }, as: :json
    end
    assert_redirected_to account_chat_path(@account, @chat)
    assert_nil @chat.reload.visual_tag
    follow_redirect!
    assert_match "no longer available", inertia_shared_props.fetch("errors").fetch("visual_tag_id")
  end

  test "foreign tag and foreign room cannot be selected" do
    foreign = accounts(:other).visual_tags.create!(label: "Other", icon: "Wrench", colour: "blue")
    patch account_chat_visual_tag_path(@account, @chat), params: { visual_tag_id: foreign.to_param }
    assert_response :not_found
    assert_nil @chat.reload.visual_tag

    foreign_chat = accounts(:other).chats.create!(title: "Other", model_id: "openrouter/auto")
    patch account_chat_visual_tag_path(@account, foreign_chat), params: { visual_tag_id: @tag.to_param }
    assert_response :not_found
  end

  test "nonmember and anonymous selection requests are refused" do
    patch account_chat_visual_tag_path(accounts(:other), @chat), params: { visual_tag_id: @tag.to_param }
    assert_response :not_found
    delete logout_path
    patch account_chat_visual_tag_path(@account, @chat), params: { visual_tag_id: @tag.to_param }
    assert_redirected_to login_path
  end

  test "chat list shared palette and chat selection are exposed together" do
    @chat.update!(visual_tag: @tag)
    get account_chats_path(@account), headers: { "X-Inertia" => "true", "X-Inertia-Version" => ViteRuby.digest }
    assert_response :success
    assert_equal [ @tag.as_json ], inertia_shared_props["visual_tags"]
    row = inertia_shared_props.fetch("chats").find { |chat| chat["id"] == @chat.to_param }
    assert_equal @tag.as_json, row.fetch("visual_tag")
  end

end
