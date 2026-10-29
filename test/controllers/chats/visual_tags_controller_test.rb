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

  test "every tag change leaves one house line in the conversation, saying who and what" do
    name = ResidentFacingName.for(@user)
    other = @account.visual_tags.create!(label: "Plans", icon: "Compass", colour: "green")
    pin = @account.visual_tags.pinned.first || @account.visual_tags.create!(**VisualTag::PIN, pinned: true)
    lines = -> { @chat.messages.where(role: "system").order(:id).pluck(:content) }

    patch account_chat_visual_tag_path(@account, @chat), params: { visual_tag_id: @tag.to_param }
    patch account_chat_visual_tag_path(@account, @chat), params: { visual_tag_id: @tag.to_param }
    patch account_chat_visual_tag_path(@account, @chat), params: { visual_tag_id: other.to_param }
    patch account_chat_visual_tag_path(@account, @chat), params: { visual_tag_id: nil }, as: :json
    patch account_chat_visual_tag_path(@account, @chat), params: { visual_tag_id: pin.to_param }
    patch account_chat_visual_tag_path(@account, @chat), params: { visual_tag_id: nil }, as: :json

    assert_equal [
      "#{name} tagged this conversation Care.",
      "#{name} changed the tag to Plans (was Care).",
      "#{name} removed the tag Plans.",
      "#{name} pinned this conversation.",
      "#{name} unpinned this conversation."
    ], lines.call
    assert @chat.messages.where(role: "system").all? { |m| m.user_id.nil? && m.agent_id.nil? }
  end

  test "an overlapping write is read under the lock: the line names the tag actually replaced" do
    name = ResidentFacingName.for(@user)
    other = @account.visual_tags.create!(label: "Plans", icon: "Compass", colour: "green")
    real_resolve = VisualTag.method(:resolve_for)
    # Another request commits Plans after this one loaded the room, before it locks.
    overlapping = ->(account, id) { Chat.where(id: @chat.id).update_all(visual_tag_id: other.id); real_resolve.call(account, id) }
    VisualTag.stub(:resolve_for, overlapping) do
      patch account_chat_visual_tag_path(@account, @chat), params: { visual_tag_id: @tag.to_param }
    end
    assert_equal [ "#{name} changed the tag to Care (was Plans)." ],
      @chat.messages.where(role: "system").pluck(:content)
  end

  test "two writers choosing the same tag log it once" do
    real_resolve = VisualTag.method(:resolve_for)
    # The other writer already committed the same choice before this one locks.
    same = ->(account, id) { Chat.where(id: @chat.id).update_all(visual_tag_id: @tag.id); real_resolve.call(account, id) }
    VisualTag.stub(:resolve_for, same) do
      patch account_chat_visual_tag_path(@account, @chat), params: { visual_tag_id: @tag.to_param }
    end
    assert_equal @tag, @chat.reload.visual_tag
    assert_empty @chat.messages.where(role: "system")
  end

  test "a refused selection leaves no line" do
    VisualTag.stub(:resolve_for, ->(*) { raise ActiveRecord::InvalidForeignKey }) do
      patch account_chat_visual_tag_path(@account, @chat), params: { visual_tag_id: @tag.to_param }, as: :json
    end
    assert_empty @chat.messages.where(role: "system")
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
    assert_equal [ @tag.as_json.merge("conversation_count" => 1) ], inertia_shared_props["visual_tags"]
    row = inertia_shared_props.fetch("chats").find { |chat| chat["id"] == @chat.to_param }
    assert_equal @tag.as_json, row.fetch("visual_tag")
  end

  test "a tag change leaves the conversation where it is in the list" do
    earlier = 2.hours.ago.change(usec: 0)
    newer = @account.chats.create!(title: "Newer", model_id: "openrouter/auto")
    @chat.update_columns(last_message_at: earlier)
    newer.update_columns(last_message_at: 1.hour.ago)
    patch account_chat_visual_tag_path(@account, @chat), params: { visual_tag_id: @tag.to_param }
    assert_equal 1, @chat.messages.where(role: "system").count
    assert_equal earlier, @chat.reload.last_message_at
    order = @account.chats.latest.where(id: [ @chat.id, newer.id ]).pluck(:id)
    assert_equal [ newer.id, @chat.id ], order
  end

end
