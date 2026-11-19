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

  def cutoffs(chats)
    chats.to_h { |chat| [ chat.to_param, @asks[@chats.index(chat)].to_param ] }
  end

  def mark_read(pairs)
    post bulk_mark_read_account_chats_path(@account), params: { through_message_ids: pairs }, as: :json
  end

  def tag_list(visual_tag_id, room: "main", **filter)
    patch bulk_visual_tag_account_chats_path(@account), params: { visual_tag_id: visual_tag_id, room: room, **filter }, as: :json
  end

  test "mark read clears every eye of mine in the chosen conversations and only those" do
    other = users(:existing_user)
    others_flag = ReplyExpectation.create!(message: @asks[0], user: other, score: 0.9, classifier_version: "test")

    mark_read(cutoffs(@chats.first(2)))
    assert_response :ok
    assert_equal @chats.first(2).map(&:to_param).sort, response.parsed_body["conversation_ids"].sort

    assert ReplyExpectation.find_by!(message: @asks[0], user: @user).state_dismissed?
    assert ReplyExpectation.find_by!(message: @asks[1], user: @user).state_dismissed?
    assert ReplyExpectation.find_by!(message: @asks[2], user: @user).state_open?
    assert others_flag.reload.state_open?
    assert_equal @asks[0].id, ReplyDismissal.find_by!(chat: @chats[0], user: @user).through_message_id
    assert AuditLog.exists?(action: "bulk_dismiss_reply_expectations", user: @user)
  end

  test "a message newer than the eye the list showed keeps its eye, flagged before or after the click" do
    before = @chats[0].messages.create!(role: "assistant", content: "Test User, and also this")
    @chats[0].with_lock { ReplyExpectation.record!(message: before, user: @user, score: 0.95) }
    after = @chats[0].messages.create!(role: "assistant", content: "Test User, one more")

    mark_read(cutoffs([ @chats[0] ]))
    assert_response :ok
    assert ReplyExpectation.find_by!(message: @asks[0], user: @user).state_dismissed?
    assert ReplyExpectation.find_by!(message: before, user: @user).state_open?

    @chats[0].with_lock { ReplyExpectation.record!(message: after, user: @user, score: 0.95) }
    assert ReplyExpectation.find_by!(message: after, user: @user).state_open?
    # ...while an old message classified late stays behind the cutoff.
    @chats[0].with_lock { ReplyExpectation.record!(message: @asks[0], user: @user, score: 0.99) }
    assert ReplyExpectation.find_by!(message: @asks[0], user: @user).state_dismissed?
  end

  test "mark read never moves an existing cutoff backwards" do
    later = @chats[0].messages.create!(role: "assistant", content: "Later")
    ReplyDismissal.create!(chat: @chats[0], user: @user, through_message_id: later.id)
    mark_read(cutoffs([ @chats[0] ]))
    assert_response :ok
    assert_equal later.id, ReplyDismissal.find_by!(chat: @chats[0], user: @user).through_message_id
  end

  test "marking read is a fixed number of queries however many conversations" do
    more = 6.times.map do |i|
      chat = @account.chats.create!(title: "More #{i}")
      ask = chat.messages.create!(role: "assistant", content: "Test User?")
      chat.with_lock { ReplyExpectation.record!(message: ask, user: @user, score: 0.95) }
      [ chat.id, ask.id ]
    end.to_h
    few_cutoffs = @chats.first(2).each_with_index.to_h { |chat, i| [ chat.id, @asks[i].id ] }
    few = sql_count { ConversationBulk.mark_read!(chats: @account.chats.kept, user: @user, cutoffs: few_cutoffs) }
    many = sql_count { ConversationBulk.mark_read!(chats: @account.chats.kept, user: @user, cutoffs: more) }
    assert_equal few, many
    assert_operator many, :<=, 4
  end

  test "tagging's transcript lines cost the same per changed conversation, on top of a fixed part" do
    batch = ->(n) { n.times.map { |i| @account.chats.create!(title: "Batch #{n}-#{i}") } }
    two = batch.call(2)
    four = batch.call(4)
    q2 = sql_count { ConversationBulk.set_tag!(chats: @account.chats.where(id: two.map(&:id)), tag: @tag, by: @user) }
    q4 = sql_count { ConversationBulk.set_tag!(chats: @account.chats.where(id: four.map(&:id)), tag: @tag, by: @user) }
    # Not fixed: two more changed rooms cost about two more rooms' lines.
    assert_operator q4, :>, q2
    assert_operator q4 - q2, :<=, 2 * 12
    assert_operator q2, :<=, 40
    (two + four).each { |chat| assert_equal @tag, chat.reload.visual_tag }
  end

  test "the cutoffs must be real messages of their own conversations, and conversations of this account" do
    foreign = accounts(:existing_user_account).chats.create!(title: "Foreign")
    foreign_ask = foreign.messages.create!(role: "assistant", content: "Elsewhere")
    deleted = @account.chats.create!(title: "Deleted")
    deleted_ask = deleted.messages.create!(role: "assistant", content: "Gone")
    deleted.discard!

    mark_read(cutoffs([ @chats[0] ]).merge(foreign.to_param => foreign_ask.to_param, deleted.to_param => deleted_ask.to_param))
    assert_response :ok
    assert_equal [ @chats[0].to_param ], response.parsed_body["conversation_ids"]

    mark_read(@chats[0].to_param => @asks[1].to_param)
    assert_response :unprocessable_entity
    assert ReplyExpectation.find_by!(message: @asks[1], user: @user).state_open?

    [ {}, nil, "abc", { @chats[0].to_param => "12" }, { "12" => @asks[0].to_param } ].each do |bad|
      mark_read(bad)
      assert_response :unprocessable_entity, "accepted #{bad.inspect}"
    end
    mark_read(Array.new(Chats::BulkActionsController::MAX_CUTOFFS + 1) { |i| [ Chat.encode_id(i + 1), Message.encode_id(i + 1) ] }.to_h)
    assert_response :unprocessable_entity
  end

  test "tagging acts on the list for that room and filter, and records it in each room" do
    @chats[2].update!(visual_tag: @tag)
    archived = @account.chats.create!(title: "Old")
    archived.archive!
    room = @account.rooms.create!(name: "Elsewhere")
    elsewhere = @account.chats.create!(title: "Other room", room: room)

    assert_difference -> { Message.where(role: "system").count }, 2 do
      tag_list(@tag.to_param, show_archived: "true")
    end
    assert_response :ok
    assert_equal @chats.first(2).map(&:to_param).sort, response.parsed_body["conversation_ids"].sort
    assert_equal @tag.to_param, response.parsed_body.dig("visual_tag", "id")
    @chats.each { |chat| assert_equal @tag, chat.reload.visual_tag }
    assert_nil archived.reload.visual_tag
    assert_nil elsewhere.reload.visual_tag
    assert_match "tagged this conversation Done", @chats[0].messages.where(role: "system").last.content
    assert AuditLog.exists?(action: "bulk_set_visual_tag", user: @user)

    tag_list(nil, room: "all", tag: @tag.to_param)
    assert_response :ok
    assert_equal 3, response.parsed_body["conversation_ids"].size
    @chats.each { |chat| assert_nil chat.reload.visual_tag }
    assert_nil elsewhere.reload.visual_tag
    assert_match "removed the tag Done", @chats[0].messages.where(role: "system").last.content

    tag_list(@tag.to_param, room: room.to_param)
    assert_equal [ elsewhere.to_param ], response.parsed_body["conversation_ids"]
  end

  test "a list longer than any ID cap is tagged in one request" do
    now = Time.current
    Chat.insert_all(Array.new(ConversationBulk::MAX_CONVERSATIONS + 1) { |i| { account_id: @account.id, title: "Long #{i}", created_at: now, updated_at: now } })
    tag_list(@tag.to_param)
    assert_response :ok
    assert_equal ConversationBulk::MAX_CONVERSATIONS + 4, response.parsed_body["conversation_ids"].size
    assert_equal 0, @account.chats.kept.active.where(visual_tag_id: nil).count
  end

  test "tagging needs a tag of this account, an explicit value and a list" do
    foreign_tag = accounts(:existing_user_account).visual_tags.create!(label: "Theirs", icon: "Heart", colour: "rose")
    tag_list(foreign_tag.to_param)
    assert_response :not_found
    patch bulk_visual_tag_account_chats_path(@account), params: { room: "main" }, as: :json
    assert_response :unprocessable_entity
    patch bulk_visual_tag_account_chats_path(@account), params: { visual_tag_id: @tag.to_param }, as: :json
    assert_response :unprocessable_entity
    assert_nil @chats[0].reload.visual_tag
  end

  test "a room or filter tag that no longer resolves refuses the tagging and writes nothing" do
    # The bystanders are @chats in Main: the old fallbacks would have tagged them.
    gone_room_key = @account.rooms.create!(name: "Gone soon").tap(&:destroy!).to_param
    gone_tag_key = @account.visual_tags.create!(label: "Building", icon: "Hammer", colour: "rose").tap(&:destroy!).to_param
    foreign_room_key = accounts(:existing_user_account).rooms.create!(name: "Theirs").to_param

    stale = [
      { room: gone_room_key },
      { room: foreign_room_key },
      { room: "main", tag: gone_tag_key },
      { room: "all", tag: gone_tag_key },
      { room: "" },
      { room: "main", tag: "x" }
    ]
    assert_no_difference -> { Message.where(role: "system").count } do
      stale.each do |scope|
        tag_list(@tag.to_param, **scope)
        assert_response :conflict, scope.inspect
        assert_match "Refresh the page", response.parsed_body["error"]
      end
    end
    @chats.each { |chat| assert_nil chat.reload.visual_tag }
    assert_not AuditLog.exists?(action: "bulk_set_visual_tag", user: @user)

    # No filter at all is a real list, and so is an empty one from the form.
    tag_list(@tag.to_param, room: "main", tag: "")
    assert_response :ok
    assert_equal 3, response.parsed_body["conversation_ids"].size
  end

end
