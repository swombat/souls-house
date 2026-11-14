require "test_helper"

class WhiteboardTest < ActiveSupport::TestCase

  test "validates name presence" do
    board = Whiteboard.new(account: accounts(:personal_account))
    assert_not board.valid?
    assert_includes board.errors[:name], "can't be blank"
  end

  test "validates name uniqueness within account for active boards" do
    existing = whiteboards(:project_notes)
    board = Whiteboard.new(account: existing.account, name: existing.name)
    assert_not board.valid?
    assert_includes board.errors[:name], "has already been taken"
  end

  test "allows duplicate names for deleted boards" do
    existing = whiteboards(:project_notes)
    existing.soft_delete!
    board = Whiteboard.new(account: existing.account, name: existing.name, summary: "New")
    assert board.valid?
  end

  test "soft_delete clears active board references" do
    board = whiteboards(:project_notes)
    account = accounts(:personal_account)
    agent = agents(:research_assistant)
    chat = Chat.new(
      account: account,
      title: "Test Chat",
      manual_responses: true,
      model_id_string: "openrouter/auto"
    )
    chat.agents << agent
    chat.save!
    chat.update!(active_whiteboard: board)

    board.soft_delete!
    chat.reload

    assert_nil chat.active_whiteboard_id
  end

  test "content change increments revision" do
    board = whiteboards(:project_notes)
    original = board.revision

    board.update!(content: "New content")

    assert_equal original + 1, board.revision
  end

  test "editor_name returns agent name" do
    board = whiteboards(:project_notes)
    board.update!(last_edited_by: agents(:research_assistant))
    assert_equal agents(:research_assistant).name, board.editor_name
  end

  test "editor_name returns the user's full name, or their email prefix when they have none" do
    board = whiteboards(:meeting_notes)
    user = users(:user_1)
    user.profile.update!(first_name: "Ada", last_name: "Lovelace")
    board.update!(last_edited_by: user)
    assert_equal "Ada Lovelace", board.reload.editor_name

    user.profile.update_columns(first_name: nil, last_name: nil) # a profile from before names were required
    assert_equal user.email_address.split("@").first, board.reload.editor_name
  end

  test "editor_name returns nil when no editor" do
    board = whiteboards(:deleted_whiteboard)
    assert_nil board.editor_name
  end

end
