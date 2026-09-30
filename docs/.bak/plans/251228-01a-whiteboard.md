# Implementation Spec: Whiteboard Feature

**Date:** 2024-12-28
**Spec ID:** 251228-01a
**Status:** Draft

## Executive Summary

The Whiteboard feature provides AI agents with shared working memory through editable "boards" that persist across conversations. Unlike private agent memories, whiteboards are shared across all agents within an account, enabling collaborative documentation, note-taking, and persistent context sharing.

Key aspects:
- Account-scoped boards with name, summary, and markdown content
- Basic revision tracking (timestamp, author, revision number)
- Board index injected into all agent system prompts
- Per-conversation "active board" for automatic context injection
- Soft-delete with automatic cleanup of active board references
- Eight tools for complete board management

## Architecture Overview

### Data Model

```
Account
  └── has_many :whiteboards (soft-deleted via deleted_at)

Chat (conversation)
  └── belongs_to :active_whiteboard (optional)

Whiteboard
  ├── belongs_to :account
  ├── belongs_to :last_edited_by (polymorphic: User | Agent)
  └── has_many :chats (as active_whiteboard)
```

### Context Injection Flow

```
Chat#system_message_for(agent)
  ├── Agent's system_prompt
  ├── Agent's memory_context (private memories)
  ├── whiteboard_index_context (NEW - all boards summary)
  ├── active_whiteboard_context (NEW - full content if active)
  └── Group chat context
```

### Tool Organization

Eight tools organized logically:
- **CRUD Operations:** `CreateBoardTool`, `UpdateBoardTool`, `GetBoardTool`, `ListBoardsTool`
- **Lifecycle:** `DeleteBoardTool`, `RestoreBoardTool`, `ViewDeletedBoardsTool`
- **Context:** `SetActiveBoardTool`

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

- [ ] Create Whiteboard model with all concerns and validations

**File:** `app/models/whiteboard.rb`

```ruby
class Whiteboard < ApplicationRecord
  include Broadcastable
  include ObfuscatesId
  include JsonAttributes

  MAX_RECOMMENDED_LENGTH = 10_000

  belongs_to :account
  belongs_to :last_edited_by, polymorphic: true, optional: true
  has_many :chats, foreign_key: :active_whiteboard_id, dependent: :nullify

  validates :name, presence: true,
                   length: { maximum: 100 },
                   uniqueness: { scope: :account_id, conditions: -> { active } }
  validates :summary, length: { maximum: 250 }
  validates :content, length: { maximum: 100_000 }

  broadcasts_to :account

  scope :active, -> { where(deleted_at: nil) }
  scope :deleted, -> { where.not(deleted_at: nil) }
  scope :by_name, -> { order(:name) }
  scope :recently_edited, -> { order(last_edited_at: :desc) }

  json_attributes :name, :summary, :content_length, :revision,
                  :last_edited_at_formatted, :last_edited_by_name,
                  :over_recommended_length?, :deleted?

  before_save :increment_revision, if: :content_changed?
  after_destroy :clear_active_board_references
  after_update :clear_active_board_references_if_deleted

  def soft_delete!
    update!(deleted_at: Time.current)
  end

  def restore!
    update!(deleted_at: nil)
  end

  def deleted?
    deleted_at.present?
  end

  def content_length
    content&.length || 0
  end

  def over_recommended_length?
    content_length > MAX_RECOMMENDED_LENGTH
  end

  def last_edited_at_formatted
    last_edited_at&.strftime("%Y-%m-%d %H:%M")
  end

  def last_edited_by_name
    case last_edited_by
    when User then last_edited_by.full_name.presence || last_edited_by.email_address.split("@").first
    when Agent then last_edited_by.name
    else nil
    end
  end

  def update_content!(new_content, editor:)
    update!(
      content: new_content,
      last_edited_by: editor,
      last_edited_at: Time.current
    )
  end

  def update_metadata!(name: nil, summary: nil, editor: nil)
    attrs = {}
    attrs[:name] = name if name.present?
    attrs[:summary] = summary if summary.present?
    if attrs.any?
      attrs[:last_edited_by] = editor if editor
      attrs[:last_edited_at] = Time.current if editor
      update!(attrs)
    end
  end

  def for_index
    {
      id: obfuscated_id,
      name: name,
      summary: summary,
      length: content_length,
      revision: revision,
      over_limit: over_recommended_length?,
      last_edited: last_edited_at_formatted
    }
  end

  private

  def increment_revision
    self.revision = (revision || 0) + 1
    self.last_edited_at = Time.current
  end

  def clear_active_board_references
    Chat.where(active_whiteboard_id: id).update_all(active_whiteboard_id: nil)
  end

  def clear_active_board_references_if_deleted
    clear_active_board_references if saved_change_to_deleted_at? && deleted?
  end
end
```

---

### Phase 3: Account Association

- [ ] Add whiteboards association to Account model

**File:** `app/models/account.rb` (modification)

Add to associations section:

```ruby
has_many :whiteboards, dependent: :destroy
```

---

### Phase 4: Chat Model Modifications

- [ ] Add active_whiteboard association to Chat
- [ ] Implement whiteboard context methods
- [ ] Modify system_message_for to inject whiteboard context

**File:** `app/models/chat.rb` (modifications)

Add association:

```ruby
belongs_to :active_whiteboard, class_name: "Whiteboard", optional: true
```

Add to json_attributes (if needed for frontend):

```ruby
json_attributes :title_or_default, :model_id, ..., :active_whiteboard_id
```

Add private methods:

```ruby
private

def whiteboard_index_context
  boards = account.whiteboards.active.by_name.to_a
  return nil if boards.empty?

  lines = boards.map do |board|
    status = board.over_recommended_length? ? " [OVER LIMIT - needs summarizing]" : ""
    "- #{board.name} (#{board.content_length} chars, rev #{board.revision})#{status}: #{board.summary}"
  end

  "# Shared Whiteboards\n\n" \
  "The following whiteboards are available for collaborative notes and documentation:\n\n" \
  "#{lines.join("\n")}\n\n" \
  "Use the board tools to view, create, update, or set an active board for this conversation."
end

def active_whiteboard_context
  return nil unless active_whiteboard&.active? # active? means not soft-deleted

  "# Active Whiteboard: #{active_whiteboard.name}\n\n" \
  "**Summary:** #{active_whiteboard.summary}\n" \
  "**Length:** #{active_whiteboard.content_length} characters (revision #{active_whiteboard.revision})\n" \
  "**Last edited:** #{active_whiteboard.last_edited_at_formatted} by #{active_whiteboard.last_edited_by_name}\n\n" \
  "---\n\n" \
  "#{active_whiteboard.content}"
end
```

Modify `system_message_for`:

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

Add public method for active board check:

```ruby
def active_whiteboard_id
  active_whiteboard&.obfuscated_id
end
```

---

### Phase 5: Tools Implementation

All tools follow the established pattern with `chat:` and `current_agent:` initialization.

#### 5.1 CreateBoardTool

- [ ] Implement CreateBoardTool

**File:** `app/tools/create_board_tool.rb`

```ruby
class CreateBoardTool < RubyLLM::Tool
  description "Create a new whiteboard for shared notes and documentation. Boards are visible to all agents."

  param :name, type: :string,
        desc: "Name for the board (must be unique within the account)",
        required: true

  param :summary, type: :string,
        desc: "Brief summary of the board's purpose (max 250 chars)",
        required: true

  param :content, type: :string,
        desc: "Initial content for the board (markdown format)",
        required: false

  def initialize(chat: nil, current_agent: nil)
    super()
    @chat = chat
    @current_agent = current_agent
  end

  def execute(name:, summary:, content: nil)
    return error("This tool only works in group conversations") unless @current_agent
    return error("No chat context available") unless @chat

    board = @chat.account.whiteboards.create!(
      name: name.to_s.strip,
      summary: summary.to_s.strip,
      content: content.to_s.strip.presence,
      last_edited_by: @current_agent,
      last_edited_at: Time.current
    )

    {
      success: true,
      board_id: board.obfuscated_id,
      name: board.name,
      summary: board.summary,
      content_length: board.content_length
    }
  rescue ActiveRecord::RecordInvalid => e
    error("Failed to create board: #{e.record.errors.full_messages.join(', ')}")
  end

  private

  def error(msg) = { error: msg }
end
```

#### 5.2 UpdateBoardTool

- [ ] Implement UpdateBoardTool

**File:** `app/tools/update_board_tool.rb`

```ruby
class UpdateBoardTool < RubyLLM::Tool
  description "Update an existing whiteboard. You can update the name, summary, and/or content."

  param :board_id, type: :string,
        desc: "ID of the board to update",
        required: true

  param :name, type: :string,
        desc: "New name for the board (leave blank to keep current)",
        required: false

  param :summary, type: :string,
        desc: "New summary for the board (leave blank to keep current)",
        required: false

  param :content, type: :string,
        desc: "New content for the board (replaces existing content)",
        required: false

  def initialize(chat: nil, current_agent: nil)
    super()
    @chat = chat
    @current_agent = current_agent
  end

  def execute(board_id:, name: nil, summary: nil, content: nil)
    return error("This tool only works in group conversations") unless @current_agent
    return error("No chat context available") unless @chat
    return error("At least one of name, summary, or content must be provided") if name.blank? && summary.blank? && content.nil?

    board = find_board(board_id)
    return error("Board not found") unless board
    return error("Cannot update a deleted board - restore it first") if board.deleted?

    updates = {}
    updates[:name] = name.to_s.strip if name.present?
    updates[:summary] = summary.to_s.strip if summary.present?
    updates[:content] = content.to_s.strip if content.present? || content == ""
    updates[:last_edited_by] = @current_agent
    updates[:last_edited_at] = Time.current

    board.update!(updates)

    response = {
      success: true,
      board_id: board.obfuscated_id,
      name: board.name,
      revision: board.revision,
      content_length: board.content_length
    }

    response[:warning] = "Board is over the recommended #{Whiteboard::MAX_RECOMMENDED_LENGTH} character limit. Consider summarizing." if board.over_recommended_length?

    response
  rescue ActiveRecord::RecordInvalid => e
    error("Failed to update board: #{e.record.errors.full_messages.join(', ')}")
  end

  private

  def find_board(board_id)
    @chat.account.whiteboards.find_by_obfuscated_id(board_id)
  end

  def error(msg) = { error: msg }
end
```

#### 5.3 GetBoardTool

- [ ] Implement GetBoardTool

**File:** `app/tools/get_board_tool.rb`

```ruby
class GetBoardTool < RubyLLM::Tool
  description "Get the full content of a specific whiteboard by ID."

  param :board_id, type: :string,
        desc: "ID of the board to retrieve",
        required: true

  def initialize(chat: nil, current_agent: nil)
    super()
    @chat = chat
    @current_agent = current_agent
  end

  def execute(board_id:)
    return error("This tool only works in group conversations") unless @current_agent
    return error("No chat context available") unless @chat

    board = find_board(board_id)
    return error("Board not found") unless board

    {
      success: true,
      board_id: board.obfuscated_id,
      name: board.name,
      summary: board.summary,
      content: board.content,
      content_length: board.content_length,
      revision: board.revision,
      last_edited_at: board.last_edited_at_formatted,
      last_edited_by: board.last_edited_by_name,
      deleted: board.deleted?
    }
  end

  private

  def find_board(board_id)
    @chat.account.whiteboards.find_by_obfuscated_id(board_id)
  end

  def error(msg) = { error: msg }
end
```

#### 5.4 ListBoardsTool

- [ ] Implement ListBoardsTool

**File:** `app/tools/list_boards_tool.rb`

```ruby
class ListBoardsTool < RubyLLM::Tool
  description "List all active whiteboards in the account with their summaries and metadata."

  def initialize(chat: nil, current_agent: nil)
    super()
    @chat = chat
    @current_agent = current_agent
  end

  def execute
    return error("This tool only works in group conversations") unless @current_agent
    return error("No chat context available") unless @chat

    boards = @chat.account.whiteboards.active.by_name.map(&:for_index)

    {
      success: true,
      count: boards.size,
      boards: boards,
      active_board_id: @chat.active_whiteboard&.obfuscated_id
    }
  end

  private

  def error(msg) = { error: msg }
end
```

#### 5.5 DeleteBoardTool

- [ ] Implement DeleteBoardTool

**File:** `app/tools/delete_board_tool.rb`

```ruby
class DeleteBoardTool < RubyLLM::Tool
  description "Soft-delete a whiteboard. The board can be restored later. If it was the active board for any conversations, it will be automatically unset."

  param :board_id, type: :string,
        desc: "ID of the board to delete",
        required: true

  def initialize(chat: nil, current_agent: nil)
    super()
    @chat = chat
    @current_agent = current_agent
  end

  def execute(board_id:)
    return error("This tool only works in group conversations") unless @current_agent
    return error("No chat context available") unless @chat

    board = find_board(board_id)
    return error("Board not found") unless board
    return error("Board is already deleted") if board.deleted?

    board.soft_delete!

    {
      success: true,
      board_id: board.obfuscated_id,
      name: board.name,
      message: "Board deleted. Use restore_board to recover it."
    }
  end

  private

  def find_board(board_id)
    @chat.account.whiteboards.find_by_obfuscated_id(board_id)
  end

  def error(msg) = { error: msg }
end
```

#### 5.6 RestoreBoardTool

- [ ] Implement RestoreBoardTool

**File:** `app/tools/restore_board_tool.rb`

```ruby
class RestoreBoardTool < RubyLLM::Tool
  description "Restore a previously deleted whiteboard."

  param :board_id, type: :string,
        desc: "ID of the board to restore",
        required: true

  def initialize(chat: nil, current_agent: nil)
    super()
    @chat = chat
    @current_agent = current_agent
  end

  def execute(board_id:)
    return error("This tool only works in group conversations") unless @current_agent
    return error("No chat context available") unless @chat

    board = find_board(board_id)
    return error("Board not found") unless board
    return error("Board is not deleted") unless board.deleted?

    # Check for name conflict with existing active board
    if @chat.account.whiteboards.active.where(name: board.name).exists?
      return error("Cannot restore: another active board already has the name '#{board.name}'")
    end

    board.restore!

    {
      success: true,
      board_id: board.obfuscated_id,
      name: board.name,
      message: "Board restored successfully."
    }
  end

  private

  def find_board(board_id)
    @chat.account.whiteboards.find_by_obfuscated_id(board_id)
  end

  def error(msg) = { error: msg }
end
```

#### 5.7 ViewDeletedBoardsTool

- [ ] Implement ViewDeletedBoardsTool

**File:** `app/tools/view_deleted_boards_tool.rb`

```ruby
class ViewDeletedBoardsTool < RubyLLM::Tool
  description "List all deleted whiteboards that can be restored."

  def initialize(chat: nil, current_agent: nil)
    super()
    @chat = chat
    @current_agent = current_agent
  end

  def execute
    return error("This tool only works in group conversations") unless @current_agent
    return error("No chat context available") unless @chat

    boards = @chat.account.whiteboards.deleted.by_name.map do |board|
      {
        id: board.obfuscated_id,
        name: board.name,
        summary: board.summary,
        deleted_at: board.deleted_at.strftime("%Y-%m-%d %H:%M"),
        content_length: board.content_length
      }
    end

    {
      success: true,
      count: boards.size,
      boards: boards
    }
  end

  private

  def error(msg) = { error: msg }
end
```

#### 5.8 SetActiveBoardTool

- [ ] Implement SetActiveBoardTool

**File:** `app/tools/set_active_board_tool.rb`

```ruby
class SetActiveBoardTool < RubyLLM::Tool
  description "Set or clear the active whiteboard for this conversation. The active board's full content is automatically included in the conversation context."

  param :board_id, type: :string,
        desc: "ID of the board to set as active, or 'none' to clear the active board",
        required: true

  def initialize(chat: nil, current_agent: nil)
    super()
    @chat = chat
    @current_agent = current_agent
  end

  def execute(board_id:)
    return error("This tool only works in group conversations") unless @current_agent
    return error("No chat context available") unless @chat

    if board_id.to_s.downcase == "none" || board_id.blank?
      @chat.update!(active_whiteboard: nil)
      return {
        success: true,
        message: "Active board cleared. No whiteboard content will be included in the context."
      }
    end

    board = find_board(board_id)
    return error("Board not found") unless board
    return error("Cannot set a deleted board as active") if board.deleted?

    @chat.update!(active_whiteboard: board)

    {
      success: true,
      board_id: board.obfuscated_id,
      name: board.name,
      message: "Active board set. The full content of '#{board.name}' will now be included in the conversation context."
    }
  end

  private

  def find_board(board_id)
    @chat.account.whiteboards.find_by_obfuscated_id(board_id)
  end

  def error(msg) = { error: msg }
end
```

---

### Phase 6: Testing Strategy

- [ ] Write model tests for Whiteboard
- [ ] Write tests for Chat whiteboard context methods
- [ ] Write tests for each tool
- [ ] Write integration tests for context injection

**File:** `test/models/whiteboard_test.rb`

```ruby
require "test_helper"

class WhiteboardTest < ActiveSupport::TestCase
  test "validates name presence" do
    board = Whiteboard.new(account: accounts(:one))
    assert_not board.valid?
    assert_includes board.errors[:name], "can't be blank"
  end

  test "validates name uniqueness within account for active boards" do
    existing = whiteboards(:one)
    board = Whiteboard.new(account: existing.account, name: existing.name)
    assert_not board.valid?
    assert_includes board.errors[:name], "has already been taken"
  end

  test "allows duplicate names for deleted boards" do
    existing = whiteboards(:one)
    existing.soft_delete!
    board = Whiteboard.new(account: existing.account, name: existing.name, summary: "New")
    assert board.valid?
  end

  test "soft delete sets deleted_at" do
    board = whiteboards(:one)
    assert_nil board.deleted_at
    board.soft_delete!
    assert_not_nil board.deleted_at
  end

  test "soft delete clears active board references" do
    board = whiteboards(:one)
    chat = chats(:group_chat)
    chat.update!(active_whiteboard: board)

    board.soft_delete!
    chat.reload

    assert_nil chat.active_whiteboard_id
  end

  test "restore clears deleted_at" do
    board = whiteboards(:one)
    board.soft_delete!
    board.restore!
    assert_nil board.deleted_at
  end

  test "content change increments revision" do
    board = whiteboards(:one)
    original_revision = board.revision

    board.update!(content: "New content")

    assert_equal original_revision + 1, board.revision
  end

  test "over_recommended_length returns true for long content" do
    board = whiteboards(:one)
    board.update!(content: "x" * 10_001)
    assert board.over_recommended_length?
  end
end
```

**File:** `test/tools/create_board_tool_test.rb`

```ruby
require "test_helper"

class CreateBoardToolTest < ActiveSupport::TestCase
  setup do
    @chat = chats(:group_chat)
    @agent = agents(:one)
    @tool = CreateBoardTool.new(chat: @chat, current_agent: @agent)
  end

  test "creates board with valid params" do
    result = @tool.execute(
      name: "Test Board",
      summary: "A test board",
      content: "Initial content"
    )

    assert result[:success]
    assert_not_nil result[:board_id]
    assert_equal "Test Board", result[:name]
  end

  test "returns error without agent" do
    tool = CreateBoardTool.new(chat: @chat, current_agent: nil)
    result = tool.execute(name: "Test", summary: "Test")
    assert_equal "This tool only works in group conversations", result[:error]
  end

  test "returns error for duplicate name" do
    @tool.execute(name: "Unique", summary: "First")
    result = @tool.execute(name: "Unique", summary: "Second")
    assert result[:error].include?("has already been taken")
  end
end
```

---

### Phase 7: Fixtures

- [ ] Add whiteboard fixtures

**File:** `test/fixtures/whiteboards.yml`

```yaml
one:
  account: one
  name: "Project Notes"
  summary: "General project notes and documentation"
  content: "# Project Notes\n\nThis is our shared project documentation."
  revision: 1
  last_edited_at: <%= 1.day.ago %>

two:
  account: one
  name: "Meeting Notes"
  summary: "Notes from team meetings"
  content: "# Meeting Notes\n\n## 2024-12-28\n\n- Discussed whiteboard feature"
  revision: 3
  last_edited_at: <%= 1.hour.ago %>

deleted_board:
  account: one
  name: "Archived Board"
  summary: "An old board that was deleted"
  content: "Old content"
  revision: 5
  deleted_at: <%= 2.days.ago %>
```

---

## Edge Cases and Error Handling

### Soft Delete Behavior
1. When a board is soft-deleted:
   - The `deleted_at` timestamp is set
   - All chats with this board as active have `active_whiteboard_id` set to `nil`
   - The board no longer appears in the index
   - The board can still be retrieved by ID (shows deleted status)

2. Name uniqueness only applies to active boards - deleted boards can have duplicate names

### Content Length Warnings
- Boards over 10,000 characters trigger a warning in the index
- The system does not truncate content automatically
- Agents are expected to summarize long boards proactively

### Polymorphic Editor Tracking
- `last_edited_by` can be either User or Agent
- For tool-based edits, the current_agent is recorded
- For future UI-based edits, the current_user would be recorded

### Context Injection Order
The system prompt is assembled in this order:
1. Agent's base system prompt
2. Agent's private memories
3. Whiteboard index (all boards summary)
4. Active whiteboard full content
5. Group chat context

This ensures agents have full context while keeping the most relevant information (active board) closest to the conversation.

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
- [ ] Implement whiteboard_index_context in Chat
- [ ] Implement active_whiteboard_context in Chat
- [ ] Modify system_message_for to inject contexts

### Tools
- [ ] CreateBoardTool
- [ ] UpdateBoardTool
- [ ] GetBoardTool
- [ ] ListBoardsTool
- [ ] DeleteBoardTool
- [ ] RestoreBoardTool
- [ ] ViewDeletedBoardsTool
- [ ] SetActiveBoardTool

### Tests
- [ ] Whiteboard model tests
- [ ] Chat context injection tests
- [ ] Tool tests (one file per tool)
- [ ] Integration tests

---

## Future Considerations (Out of Scope)

1. **Version history**: Full content versioning could be added later
2. **Board permissions**: Currently all agents can edit all boards
3. **UI for boards**: Frontend CRUD interface for human users
4. **Board templates**: Pre-populated board templates
5. **Board locking**: Prevent concurrent edits
6. **Board archiving**: Separate from soft-delete for long-term storage
