require "test_helper"

# The sidebar's Actions menu (JWboWj): many conversations marked read or
# tagged in one request, with a query count that does not grow with them.
class Chats::BulkActionsControllerTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:user_1)
    @account = accounts(:personal_account)
    @chats = 3.times.map { |i| @account.chats.create!(title: "Bulk #{i}") }
    @asks = @chats.map do |chat|
      ask = chat.messages.create!(role: "assistant", content: "Test User, please reply")
      chat.with_lock { ReplyExpectation.record!(message: ask, user: @user, score: 0.95) }
      ask
    end
    @tag = @account.visual_tags.create!(label: "Done", icon: "Check", colour: "rose")
    post login_path, params: { email_address: @user.email_address, password: "password123" }
  end

  def sql_count
    count = 0
    counter = ->(*, payload) { count += 1 unless payload[:name].in?([ "SCHEMA", "TRANSACTION" ]) || payload[:sql].match?(/\A\s*(BEGIN|COMMIT|SAVEPOINT|RELEASE)/i) }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { yield }
    count
  end

  test "mark read clears every eye of mine in the chosen conversations and only those" do
    other = users(:existing_user)
    others_flag = ReplyExpectation.create!(message: @asks[0], user: other, score: 0.9, classifier_version: "test")

    post bulk_mark_read_account_chats_path(@account), params: { conversation_ids: @chats.first(2).map(&:to_param) }, as: :json
    assert_response :ok
    assert_equal @chats.first(2).map(&:to_param).sort, response.parsed_body["conversation_ids"].sort

    assert ReplyExpectation.find_by!(message: @asks[0], user: @user).state_dismissed?
    assert ReplyExpectation.find_by!(message: @asks[1], user: @user).state_dismissed?
    assert ReplyExpectation.find_by!(message: @asks[2], user: @user).state_open?
    assert others_flag.reload.state_open?
    assert_equal @asks[0].id, ReplyDismissal.find_by!(chat: @chats[0], user: @user).through_message_id
    assert AuditLog.exists?(action: "bulk_dismiss_reply_expectations", user: @user)
  end

  test "a late classification of an old message stays dismissed, a new one still flags" do
    post bulk_mark_read_account_chats_path(@account), params: { conversation_ids: [ @chats[0].to_param ] }, as: :json
    assert_response :ok
    @chats[0].with_lock { ReplyExpectation.record!(message: @asks[0], user: @user, score: 0.99) }
    assert ReplyExpectation.find_by!(message: @asks[0], user: @user).state_dismissed?

    newer = @chats[0].messages.create!(role: "assistant", content: "One more thing")
    @chats[0].with_lock { ReplyExpectation.record!(message: newer, user: @user, score: 0.95) }
    assert ReplyExpectation.find_by!(message: newer, user: @user).state_open?
  end

  test "mark read never moves an existing cutoff backwards" do
    later = @chats[0].messages.create!(role: "assistant", content: "Later")
    ReplyDismissal.create!(chat: @chats[0], user: @user, through_message_id: later.id + 1000)
    post bulk_mark_read_account_chats_path(@account), params: { conversation_ids: [ @chats[0].to_param ] }, as: :json
    assert_response :ok
    assert_equal later.id + 1000, ReplyDismissal.find_by!(chat: @chats[0], user: @user).through_message_id
  end

  test "the work is a fixed number of queries however many conversations are chosen" do
    more = 6.times.map do |i|
      chat = @account.chats.create!(title: "More #{i}")
      ask = chat.messages.create!(role: "assistant", content: "Test User?")
      chat.with_lock { ReplyExpectation.record!(message: ask, user: @user, score: 0.95) }
      chat
    end
    few = sql_count { ConversationBulk.mark_read!(chats: @account.chats.where(id: @chats.first(2).map(&:id)), user: @user) }
    many = sql_count { ConversationBulk.mark_read!(chats: @account.chats.where(id: more.map(&:id)), user: @user) }
    assert_equal few, many
    assert_operator many, :<=, 5

    few = sql_count { ConversationBulk.set_tag!(chats: @account.chats.where(id: []), tag: @tag, by: @user) }
    assert_operator few, :<=, 1
  end

  test "foreign, deleted and unknown conversations are skipped, malformed IDs refused" do
    foreign = accounts(:existing_user_account).chats.create!(title: "Foreign")
    deleted = @account.chats.create!(title: "Deleted").tap(&:discard!)
    post bulk_mark_read_account_chats_path(@account),
      params: { conversation_ids: [ @chats[0].to_param, foreign.to_param, deleted.to_param ] }, as: :json
    assert_response :ok
    assert_equal [ @chats[0].to_param ], response.parsed_body["conversation_ids"]

    [ [], [ "12" ], [ 12 ], "abc", nil ].each do |bad|
      post bulk_mark_read_account_chats_path(@account), params: { conversation_ids: bad }, as: :json
      assert_response :unprocessable_entity, "accepted #{bad.inspect}"
    end
    post bulk_mark_read_account_chats_path(@account),
      params: { conversation_ids: Array.new(ConversationBulk::MAX_CONVERSATIONS + 1) { |i| Chat.encode_id(i + 1) } }, as: :json
    assert_response :unprocessable_entity
  end

  test "tagging sets the tag on all of them in one go and records it in each room" do
    @chats[2].update!(visual_tag: @tag)
    archived = @account.chats.create!(title: "Old")
    archived.archive!
    ids = (@chats + [ archived ]).map(&:to_param)

    assert_difference -> { Message.where(role: "system").count }, 2 do
      patch bulk_visual_tag_account_chats_path(@account), params: { conversation_ids: ids, visual_tag_id: @tag.to_param }, as: :json
    end
    assert_response :ok
    assert_equal @chats.first(2).map(&:to_param).sort, response.parsed_body["conversation_ids"].sort
    assert_equal @tag.to_param, response.parsed_body.dig("visual_tag", "id")
    @chats.each { |chat| assert_equal @tag, chat.reload.visual_tag }
    assert_nil archived.reload.visual_tag
    assert_match "tagged this conversation Done", @chats[0].messages.where(role: "system").last.content
    assert AuditLog.exists?(action: "bulk_set_visual_tag", user: @user)

    patch bulk_visual_tag_account_chats_path(@account), params: { conversation_ids: ids, visual_tag_id: nil }, as: :json
    assert_response :ok
    assert_equal 3, response.parsed_body["conversation_ids"].size
    @chats.each { |chat| assert_nil chat.reload.visual_tag }
    assert_match "removed the tag Done", @chats[0].messages.where(role: "system").last.content
  end

  test "tagging needs a tag of this account and an explicit value" do
    foreign_tag = accounts(:existing_user_account).visual_tags.create!(label: "Theirs", icon: "Heart", colour: "rose")
    patch bulk_visual_tag_account_chats_path(@account), params: { conversation_ids: [ @chats[0].to_param ], visual_tag_id: foreign_tag.to_param }, as: :json
    assert_response :not_found
    patch bulk_visual_tag_account_chats_path(@account), params: { conversation_ids: [ @chats[0].to_param ] }, as: :json
    assert_response :unprocessable_entity
    assert_nil @chats[0].reload.visual_tag
  end

end
