# Implementation Spec: Whiteboard Feature (Final)

**Date:** 2024-12-28
**Spec ID:** 251228-01d
**Status:** Ready for Implementation
**Previous:** 251228-01c (polymorphic-tools pattern update)

## Executive Summary

Shared whiteboards for AI agents. Account-scoped markdown boards with basic revision tracking. One tool handles all operations. Soft-delete with restore. Per-conversation active board injection.

This revision updates WhiteboardTool to follow the polymorphic-tools pattern exactly.

---

## Architecture Overview

### Data Model

```
Account
  has_many :whiteboards

Chat
  belongs_to :active_whiteboard (optional)

Whiteboard
  belongs_to :account
  belongs_to :last_edited_by (polymorphic: User | Agent)
```

### Context Injection Flow

```
Chat#system_message_for(agent)
  1. Agent's system_prompt
  2. Agent's memory_context (private memories)
  3. whiteboard_index_context (NEW - all boards summary)
  4. active_whiteboard_context (NEW - full content if active)
  5. Group chat context
```

### Single Tool Design

One `WhiteboardTool` class handles all operations via an `action` parameter:
- `create` - Create a new board
- `update` - Update an existing board
- `get` - Get a board by ID
- `list` - List all active boards
- `delete` - Soft-delete a board
- `restore` - Restore a deleted board
- `list_deleted` - List deleted boards
- `set_active` - Set/clear the active board for this conversation

---

## Implementation Plan

### Phase 1: Database Schema

- [ ] Create migration for whiteboards table

**File:** `db/migrate/YYYYMMDDHHMMSS_create_whiteboards.rb`

```ruby
class CreateWhiteboards < ActiveRecord::Migration[8.1]
  def change
    create_table :whiteboards do |t|
      t.references :account, null: false, foreign_key: true
      t.string :name, null: false
      t.string :summary, limit: 250
      t.text :content
      t.integer :revision, null: false, default: 1
      t.references :last_edited_by, polymorphic: true
      t.datetime :last_edited_at
      t.datetime :deleted_at

      t.timestamps
    end

    add_index :whiteboards, [:account_id, :name], unique: true, where: "deleted_at IS NULL"
    add_index :whiteboards, [:account_id, :deleted_at]
  end
end
```

- [ ] Add active_whiteboard_id to chats table

**File:** `db/migrate/YYYYMMDDHHMMSS_add_active_whiteboard_to_chats.rb`

```ruby
class AddActiveWhiteboardToChats < ActiveRecord::Migration[8.1]
  def change
    add_reference :chats, :active_whiteboard, foreign_key: { to_table: :whiteboards }
  end
end
```

---

### Phase 2: Whiteboard Model

- [ ] Create Whiteboard model

**File:** `app/models/whiteboard.rb`

```ruby
class Whiteboard < ApplicationRecord
  include Broadcastable
  include ObfuscatesId

  MAX_RECOMMENDED_LENGTH = 10_000

  belongs_to :account
  belongs_to :last_edited_by, polymorphic: true, optional: true

  validates :name, presence: true,
                   length: { maximum: 100 },
                   uniqueness: { scope: :account_id, conditions: -> { active } }
  validates :summary, length: { maximum: 250 }
  validates :content, length: { maximum: 100_000 }

  broadcasts_to :account

  scope :active, -> { where(deleted_at: nil) }
  scope :deleted, -> { where.not(deleted_at: nil) }
  scope :by_name, -> { order(:name) }

  before_save :increment_revision, if: :content_changed?
  after_save :clear_active_references, if: :became_deleted?

  def soft_delete!
    update!(deleted_at: Time.current)
  end

  def restore!
    update!(deleted_at: nil)
  end

  def deleted?
    deleted_at.present?
  end

  def over_recommended_length?
    content.to_s.length > MAX_RECOMMENDED_LENGTH
  end

  def editor_name
    case last_edited_by
    when User then last_edited_by.full_name.presence || last_edited_by.email_address.split("@").first
    when Agent then last_edited_by.name
    end
  end

  private

  def increment_revision
    self.revision = (revision || 0) + 1
    self.last_edited_at = Time.current
  end

  def became_deleted?
    saved_change_to_deleted_at? && deleted?
  end

  def clear_active_references
    Chat.where(active_whiteboard_id: id).update_all(active_whiteboard_id: nil)
  end
end
```

---

### Phase 3: Account Association

- [ ] Add whiteboards association to Account model

**File:** `app/models/account.rb` (add to associations section)

```ruby
has_many :whiteboards, dependent: :destroy
```

---

### Phase 4: Chat Model Modifications

- [ ] Add active_whiteboard association and context methods

**File:** `app/models/chat.rb` (modifications)

Add association near other belongs_to:

```ruby
belongs_to :active_whiteboard, class_name: "Whiteboard", optional: true
```

Add private methods for context injection:

```ruby
private

def whiteboard_index_context
  boards = account.whiteboards.active.by_name
  return if boards.empty?

  lines = boards.map do |b|
    warning = b.over_recommended_length? ? " [OVER LIMIT - needs summarizing]" : ""
    "- #{b.name} (#{b.content.to_s.length} chars, rev #{b.revision})#{warning}: #{b.summary}"
  end

  "# Shared Whiteboards\n\n" \
  "Available boards for collaborative notes:\n\n" \
  "#{lines.join("\n")}\n\n" \
  "Use the whiteboard tool to view, create, update, or set an active board."
end

def active_whiteboard_context
  return unless active_whiteboard && !active_whiteboard.deleted?

  "# Active Whiteboard: #{active_whiteboard.name}\n\n" \
  "#{active_whiteboard.content}"
end
```

Modify `system_message_for` to inject whiteboard contexts (add after memory_context, before group chat context):

```ruby
def system_message_for(agent)
  parts = []

  parts << (agent.system_prompt.presence || "You are #{agent.name}.")

  if (memory_context = agent.memory_context)
    parts << memory_context
  end

  if (whiteboard_index = whiteboard_index_context)
    parts << whiteboard_index
  end

  if (active_board = active_whiteboard_context)
    parts << active_board
  end

  parts << "You are participating in a group conversation."
  parts << "Other participants: #{participant_description(agent)}."

  { role: "system", content: parts.join("\n\n") }
end
```

---

### Phase 5: WhiteboardTool Implementation

- [ ] Create single unified WhiteboardTool following polymorphic-tools pattern

**File:** `app/tools/whiteboard_tool.rb`

```ruby
class WhiteboardTool < RubyLLM::Tool
  ACTIONS = %w[create update get list delete restore list_deleted set_active].freeze

  description "Manage shared whiteboards. Actions: #{ACTIONS.join(', ')}."

  param :action, type: :string,
        desc: "Action: #{ACTIONS.join(', ')}",
        required: true

  param :board_id, type: :string,
        desc: "Board ID (for: update, get, delete, restore, set_active)",
        required: false

  param :name, type: :string,
        desc: "Board name (required for create, optional for update)",
        required: false

  param :summary, type: :string,
        desc: "Board summary, max 250 chars (required for create, optional for update)",
        required: false

  param :content, type: :string,
        desc: "Markdown content. Update: omit to keep, empty string to clear.",
        required: false

  def initialize(chat: nil, current_agent: nil)
    super()
    @chat = chat
    @agent = current_agent
  end

  def execute(action:, **params)
    return validation_error("Requires group conversation context") unless @agent && @chat
    return validation_error("Invalid action '#{action}'") unless ACTIONS.include?(action)

    send("#{action}_action", **params)
  end

  private

  def create_action(name:, summary:, content: nil, **)
    return param_error("create", "name") if name.blank?
    return param_error("create", "summary") if summary.blank?

    board = whiteboards.create!(
      name: name.strip, summary: summary.strip, content: content&.strip,
      last_edited_by: @agent, last_edited_at: Time.current
    )
    { type: "board_created", board_id: board.obfuscated_id, name: board.name,
      summary: board.summary, content_length: board.content.to_s.length }
  rescue ActiveRecord::RecordInvalid => e
    validation_error(e.record.errors.full_messages.join(", "))
  end

  def update_action(board_id:, name: nil, summary: nil, content: nil, **)
    board = find_board(board_id) or return validation_error("Board not found")
    return validation_error("Cannot update deleted board - restore first") if board.deleted?
    return validation_error("Provide name, summary, or content") if name.nil? && summary.nil? && content.nil?

    updates = { last_edited_by: @agent, last_edited_at: Time.current }
    updates[:name] = name.strip if name.present?
    updates[:summary] = summary.strip if summary.present?
    updates[:content] = content&.strip unless content.nil?
    board.update!(updates)

    result = { type: "board_updated", board_id: board.obfuscated_id, name: board.name,
               revision: board.revision, content_length: board.content.to_s.length }
    result[:warning] = "Exceeds #{Whiteboard::MAX_RECOMMENDED_LENGTH} chars" if board.over_recommended_length?
    result
  rescue ActiveRecord::RecordInvalid => e
    validation_error(e.record.errors.full_messages.join(", "))
  end

  def get_action(board_id:, **)
    board = find_board(board_id) or return validation_error("Board not found")
    { type: "board", board_id: board.obfuscated_id, name: board.name, summary: board.summary,
      content: board.content, revision: board.revision, content_length: board.content.to_s.length,
      last_edited_at: board.last_edited_at&.iso8601, last_edited_by: board.editor_name, deleted: board.deleted? }
  end

  def list_action(**)
    boards = whiteboards.active.by_name.map do |b|
      { id: b.obfuscated_id, name: b.name, summary: b.summary, length: b.content.to_s.length,
        revision: b.revision, over_limit: b.over_recommended_length? }
    end
    { type: "board_list", count: boards.size, boards: boards, active_board_id: @chat.active_whiteboard&.obfuscated_id }
  end

  def delete_action(board_id:, **)
    board = find_board(board_id) or return validation_error("Board not found")
    return validation_error("Board already deleted") if board.deleted?

    board.soft_delete!
    { type: "board_deleted", board_id: board.obfuscated_id, name: board.name }
  end

  def restore_action(board_id:, **)
    board = find_board(board_id) or return validation_error("Board not found")
    return validation_error("Board is not deleted") unless board.deleted?
    return validation_error("Name '#{board.name}' already in use") if whiteboards.active.exists?(name: board.name)

    board.restore!
    { type: "board_restored", board_id: board.obfuscated_id, name: board.name }
  end

  def list_deleted_action(**)
    boards = whiteboards.deleted.by_name.map do |b|
      { id: b.obfuscated_id, name: b.name, summary: b.summary, deleted_at: b.deleted_at.iso8601, length: b.content.to_s.length }
    end
    { type: "deleted_board_list", count: boards.size, boards: boards }
  end

  def set_active_action(board_id: nil, **)
    if board_id.blank? || board_id.to_s.downcase == "none"
      @chat.update!(active_whiteboard: nil)
      return { type: "active_board_cleared" }
    end

    board = find_board(board_id) or return validation_error("Board not found")
    return validation_error("Cannot set deleted board as active") if board.deleted?

    @chat.update!(active_whiteboard: board)
    { type: "active_board_set", board_id: board.obfuscated_id, name: board.name }
  end

  def whiteboards = @chat.account.whiteboards
  def find_board(id) = id.present? ? whiteboards.find_by_obfuscated_id(id) : nil
  def validation_error(msg) = { type: "error", error: msg, allowed_actions: ACTIONS }
  def param_error(action, param) = { type: "error", error: "#{param} required for #{action}", allowed_actions: ACTIONS }
end
```

---

### Phase 6: Fixtures

- [ ] Add whiteboard fixtures

**File:** `test/fixtures/whiteboards.yml`

```yaml
project_notes:
  account: personal_account
  name: "Project Notes"
  summary: "General project notes and documentation"
  content: "# Project Notes\n\nThis is our shared project documentation."
  revision: 1
  last_edited_by: research_assistant (Agent)
  last_edited_at: <%= 1.day.ago %>

meeting_notes:
  account: personal_account
  name: "Meeting Notes"
  summary: "Notes from team meetings"
  content: "# Meeting Notes\n\n## 2024-12-28\n\n- Discussed whiteboard feature"
  revision: 3
  last_edited_by: user_1 (User)
  last_edited_at: <%= 1.hour.ago %>

deleted_whiteboard:
  account: personal_account
  name: "Archived Board"
  summary: "An old board that was deleted"
  content: "Old content that is preserved for potential restore"
  revision: 5
  last_edited_at: <%= 1.week.ago %>
  deleted_at: <%= 2.days.ago %>

other_account_whiteboard:
  account: team_account
  name: "Team Board"
  summary: "Board belonging to another account"
  content: "Team content"
  revision: 1
  last_edited_at: <%= 1.day.ago %>
```

- [ ] Add chat fixtures for whiteboard testing

**File:** `test/fixtures/chats.yml` (add to existing or create)

```yaml
group_chat:
  account: personal_account
  title: "Group Discussion"
  manual_responses: true
  model_id_string: "openrouter/auto"
```

---

### Phase 7: Tests

- [ ] Write model tests for Whiteboard

**File:** `test/models/whiteboard_test.rb`

```ruby
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

  test "soft_delete sets deleted_at" do
    board = whiteboards(:project_notes)
    assert_nil board.deleted_at
    board.soft_delete!
    assert_not_nil board.deleted_at
  end

  test "soft_delete clears active board references" do
    board = whiteboards(:project_notes)
    chat = chats(:group_chat)
    chat.update!(active_whiteboard: board)

    board.soft_delete!
    chat.reload

    assert_nil chat.active_whiteboard_id
  end

  test "restore clears deleted_at" do
    board = whiteboards(:deleted_whiteboard)
    assert board.deleted?
    board.update!(name: "Unique Name For Restore")
    board.restore!
    assert_not board.deleted?
  end

  test "content change increments revision" do
    board = whiteboards(:project_notes)
    original = board.revision

    board.update!(content: "New content")

    assert_equal original + 1, board.revision
  end

  test "over_recommended_length? returns true for long content" do
    board = whiteboards(:project_notes)
    board.update!(content: "x" * 10_001)
    assert board.over_recommended_length?
  end

  test "over_recommended_length? returns false for short content" do
    board = whiteboards(:project_notes)
    assert_not board.over_recommended_length?
  end

  test "editor_name returns agent name" do
    board = whiteboards(:project_notes)
    assert_equal agents(:research_assistant).name, board.editor_name
  end

  test "editor_name returns user name or email prefix" do
    board = whiteboards(:meeting_notes)
    user = users(:user_1)
    expected = user.full_name.presence || user.email_address.split("@").first
    assert_equal expected, board.editor_name
  end

  test "editor_name returns nil when no editor" do
    board = whiteboards(:deleted_whiteboard)
    assert_nil board.editor_name
  end

  test "deleted? returns true for deleted boards" do
    assert whiteboards(:deleted_whiteboard).deleted?
  end

  test "deleted? returns false for active boards" do
    assert_not whiteboards(:project_notes).deleted?
  end
end
```

- [ ] Write tool tests for WhiteboardTool following polymorphic pattern

**File:** `test/tools/whiteboard_tool_test.rb`

```ruby
require "test_helper"

class WhiteboardToolTest < ActiveSupport::TestCase
  setup do
    @chat = chats(:group_chat)
    @agent = agents(:research_assistant)
    @tool = WhiteboardTool.new(chat: @chat, current_agent: @agent)
  end

  test "create returns board_created type" do
    result = @tool.execute(
      action: "create",
      name: "New Board",
      summary: "A test board",
      content: "Initial content"
    )

    assert_equal "board_created", result[:type]
    assert_not_nil result[:board_id]
    assert_equal "New Board", result[:name]
  end

  test "create without name returns param error with allowed_actions" do
    result = @tool.execute(action: "create", summary: "Test")

    assert_equal "error", result[:type]
    assert_match(/name required/, result[:error])
    assert_equal WhiteboardTool::ACTIONS, result[:allowed_actions]
  end

  test "create without summary returns param error with allowed_actions" do
    result = @tool.execute(action: "create", name: "Test")

    assert_equal "error", result[:type]
    assert_match(/summary required/, result[:error])
    assert_equal WhiteboardTool::ACTIONS, result[:allowed_actions]
  end

  test "update returns board_updated type" do
    board = whiteboards(:project_notes)
    result = @tool.execute(
      action: "update",
      board_id: board.obfuscated_id,
      content: "Updated content"
    )

    assert_equal "board_updated", result[:type]
    assert_equal board.revision + 1, result[:revision]
  end

  test "update with empty string clears content" do
    board = whiteboards(:project_notes)
    result = @tool.execute(
      action: "update",
      board_id: board.obfuscated_id,
      content: ""
    )

    assert_equal "board_updated", result[:type]
    assert_equal 0, result[:content_length]
    assert_equal "", board.reload.content
  end

  test "update fails for deleted board with error type" do
    board = whiteboards(:deleted_whiteboard)
    result = @tool.execute(
      action: "update",
      board_id: board.obfuscated_id,
      content: "New content"
    )

    assert_equal "error", result[:type]
    assert_match(/deleted/, result[:error])
    assert_equal WhiteboardTool::ACTIONS, result[:allowed_actions]
  end

  test "get returns board type with full details" do
    board = whiteboards(:project_notes)
    result = @tool.execute(action: "get", board_id: board.obfuscated_id)

    assert_equal "board", result[:type]
    assert_equal board.name, result[:name]
    assert_equal board.content, result[:content]
    assert_equal board.editor_name, result[:last_edited_by]
  end

  test "list returns board_list type with active boards only" do
    result = @tool.execute(action: "list")

    assert_equal "board_list", result[:type]
    names = result[:boards].map { |b| b[:name] }
    assert_includes names, "Project Notes"
    assert_not_includes names, "Archived Board"
  end

  test "delete returns board_deleted type" do
    board = whiteboards(:project_notes)
    result = @tool.execute(action: "delete", board_id: board.obfuscated_id)

    assert_equal "board_deleted", result[:type]
    assert board.reload.deleted?
  end

  test "delete already deleted board returns error" do
    board = whiteboards(:deleted_whiteboard)
    result = @tool.execute(action: "delete", board_id: board.obfuscated_id)

    assert_equal "error", result[:type]
    assert_match(/already deleted/, result[:error])
    assert_equal WhiteboardTool::ACTIONS, result[:allowed_actions]
  end

  test "restore returns board_restored type" do
    board = whiteboards(:deleted_whiteboard)
    board.update!(name: "Unique Restore Name")
    result = @tool.execute(action: "restore", board_id: board.obfuscated_id)

    assert_equal "board_restored", result[:type]
    assert_not board.reload.deleted?
  end

  test "restore fails if name conflicts" do
    deleted = whiteboards(:deleted_whiteboard)
    deleted.update!(name: whiteboards(:project_notes).name)

    result = @tool.execute(action: "restore", board_id: deleted.obfuscated_id)

    assert_equal "error", result[:type]
    assert_match(/already in use/, result[:error])
    assert_equal WhiteboardTool::ACTIONS, result[:allowed_actions]
  end

  test "list_deleted returns deleted_board_list type" do
    result = @tool.execute(action: "list_deleted")

    assert_equal "deleted_board_list", result[:type]
    names = result[:boards].map { |b| b[:name] }
    assert_includes names, "Archived Board"
    assert_not_includes names, "Project Notes"
  end

  test "set_active returns active_board_set type" do
    board = whiteboards(:project_notes)
    result = @tool.execute(action: "set_active", board_id: board.obfuscated_id)

    assert_equal "active_board_set", result[:type]
    assert_equal board, @chat.reload.active_whiteboard
  end

  test "set_active with none returns active_board_cleared type" do
    board = whiteboards(:project_notes)
    @chat.update!(active_whiteboard: board)

    result = @tool.execute(action: "set_active", board_id: "none")

    assert_equal "active_board_cleared", result[:type]
    assert_nil @chat.reload.active_whiteboard
  end

  test "set_active with blank board_id clears active board" do
    board = whiteboards(:project_notes)
    @chat.update!(active_whiteboard: board)

    result = @tool.execute(action: "set_active", board_id: nil)

    assert_equal "active_board_cleared", result[:type]
    assert_nil @chat.reload.active_whiteboard
  end

  test "set_active fails for deleted board" do
    board = whiteboards(:deleted_whiteboard)
    result = @tool.execute(action: "set_active", board_id: board.obfuscated_id)

    assert_equal "error", result[:type]
    assert_match(/deleted/, result[:error])
    assert_equal WhiteboardTool::ACTIONS, result[:allowed_actions]
  end

  test "invalid action returns error with allowed_actions" do
    result = @tool.execute(action: "unknown")

    assert_equal "error", result[:type]
    assert_match(/Invalid action/, result[:error])
    assert_equal WhiteboardTool::ACTIONS, result[:allowed_actions]
  end

  test "requires agent context" do
    tool = WhiteboardTool.new(chat: @chat, current_agent: nil)
    result = tool.execute(action: "list")

    assert_equal "error", result[:type]
    assert_match(/context/, result[:error])
    assert_equal WhiteboardTool::ACTIONS, result[:allowed_actions]
  end

  test "board not found returns error with allowed_actions" do
    result = @tool.execute(action: "get", board_id: "nonexistent")

    assert_equal "error", result[:type]
    assert_match(/not found/, result[:error])
    assert_equal WhiteboardTool::ACTIONS, result[:allowed_actions]
  end
end
```

- [ ] Write Chat context injection tests

**File:** `test/models/chat_whiteboard_test.rb`

```ruby
require "test_helper"

class ChatWhiteboardTest < ActiveSupport::TestCase
  test "whiteboard_index_context includes active boards" do
    chat = chats(:group_chat)
    context = chat.send(:whiteboard_index_context)

    assert_includes context, "Project Notes"
    assert_includes context, "Meeting Notes"
    assert_not_includes context, "Archived Board"
  end

  test "whiteboard_index_context returns nil when no boards" do
    chat = chats(:group_chat)
    chat.account.whiteboards.destroy_all

    assert_nil chat.send(:whiteboard_index_context)
  end

  test "whiteboard_index_context marks over-limit boards" do
    chat = chats(:group_chat)
    board = whiteboards(:project_notes)
    board.update!(content: "x" * 11_000)

    context = chat.send(:whiteboard_index_context)
    assert_includes context, "[OVER LIMIT"
  end

  test "active_whiteboard_context returns nil without active board" do
    chat = chats(:group_chat)
    assert_nil chat.send(:active_whiteboard_context)
  end

  test "active_whiteboard_context includes board content" do
    chat = chats(:group_chat)
    board = whiteboards(:project_notes)
    chat.update!(active_whiteboard: board)

    context = chat.send(:active_whiteboard_context)
    assert_includes context, board.name
    assert_includes context, board.content
  end

  test "active_whiteboard_context returns nil for deleted active board" do
    chat = chats(:group_chat)
    board = whiteboards(:project_notes)
    chat.update!(active_whiteboard: board)
    board.soft_delete!

    assert_nil chat.send(:active_whiteboard_context)
  end

  test "system_message_for includes whiteboard contexts" do
    chat = chats(:group_chat)
    agent = agents(:research_assistant)
    board = whiteboards(:project_notes)
    chat.update!(active_whiteboard: board)

    message = chat.send(:system_message_for, agent)

    assert_includes message[:content], "Shared Whiteboards"
    assert_includes message[:content], "Active Whiteboard"
    assert_includes message[:content], board.content
  end
end
```

---

## Implementation Checklist

### Database
- [ ] Create whiteboards table migration
- [ ] Add active_whiteboard_id to chats migration
- [ ] Run migrations
- [ ] Add fixtures

### Models
- [ ] Create Whiteboard model
- [ ] Add whiteboards association to Account
- [ ] Add active_whiteboard association to Chat
- [ ] Add whiteboard_index_context to Chat
- [ ] Add active_whiteboard_context to Chat
- [ ] Modify system_message_for to inject contexts

### Tool
- [ ] Create WhiteboardTool following polymorphic-tools pattern

### Tests
- [ ] Whiteboard model tests
- [ ] WhiteboardTool tests (verify type-discriminated responses)
- [ ] Chat context injection tests

---

## Polymorphic-Tools Pattern Compliance

This implementation follows the polymorphic-tools pattern exactly:

1. **ACTIONS constant** - `ACTIONS = %w[create update get list delete restore list_deleted set_active].freeze`

2. **Type-discriminated responses** - All responses include a `type` field:
   - `board_created` - New board created
   - `board_updated` - Existing board updated
   - `board` - Single board details (for get)
   - `board_list` - List of active boards
   - `board_deleted` - Board soft-deleted
   - `board_restored` - Deleted board restored
   - `deleted_board_list` - List of deleted boards
   - `active_board_set` - Active board set for conversation
   - `active_board_cleared` - Active board cleared
   - `error` - All error responses

3. **Self-correcting errors** - All errors include `allowed_actions: ACTIONS`

4. **Action method naming** - Uses `_action` suffix: `create_action`, `update_action`, etc.

5. **send for routing** - `send("#{action}_action", **params)`

6. **Helper methods** - `validation_error` and `param_error` for consistent error formatting

7. **nil for unset values** - Returns `nil` for missing editor, etc.

8. **Under 100 lines** - Tool is ~95 lines (excluding blank lines in comments)

---

## Edge Cases and Design Notes

### Soft Delete Behavior
1. Deleted boards are excluded from index context
2. Deleted boards clear any active_whiteboard references (via after_save callback)
3. Name uniqueness only applies to active boards (partial unique index)
4. Deleted boards can be retrieved by ID (shows deleted status in response)
5. Cannot update or set deleted boards as active
6. Content is preserved on deletion for potential restore

### Name Conflicts on Restore
- If restoring a board whose name matches an active board, the restore fails
- User must rename the active board or delete it first

### Content Length
- Warning at 10,000+ characters in update response
- Index shows [OVER LIMIT - needs summarizing] marker
- No automatic truncation - agents self-regulate

### Polymorphic Editor Tracking
- `last_edited_by` tracks User or Agent as last editor
- For tool edits: records the current_agent
- For future UI edits: will record current_user
- `editor_name` method handles both cases elegantly

### Update Content Parameter
The `update_action` uses `content.nil?` instead of `content.blank?` deliberately:
- Omitting content parameter: preserves existing content
- Passing empty string: clears content
- This allows explicit content clearing while defaulting to preservation

---

## Files to Create/Modify

### New Files
- `db/migrate/YYYYMMDDHHMMSS_create_whiteboards.rb`
- `db/migrate/YYYYMMDDHHMMSS_add_active_whiteboard_to_chats.rb`
- `app/models/whiteboard.rb`
- `app/tools/whiteboard_tool.rb`
- `test/fixtures/whiteboards.yml`
- `test/fixtures/chats.yml` (if not existing)
- `test/models/whiteboard_test.rb`
- `test/tools/whiteboard_tool_test.rb`
- `test/models/chat_whiteboard_test.rb`

### Modified Files
- `app/models/account.rb` - Add whiteboards association
- `app/models/chat.rb` - Add active_whiteboard and context methods
