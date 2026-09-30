# DHH Review: Whiteboard Implementation Spec

**Reviewer:** DHH-style Code Review
**Date:** 2024-12-28
**Verdict:** This spec needs surgery before implementation.

---

## Overall Assessment

This spec suffers from the classic disease of over-engineering. You have taken a simple requirement for "shared notepads that agents can edit" and turned it into an enterprise content management system with eight separate tool classes, polymorphic editor tracking, soft-delete with restoration, and a revision system. The requirements asked for whiteboards. The spec delivers a bureaucracy.

The core sin here is **premature abstraction**. Eight tools when four would suffice. Polymorphic `last_edited_by` when a simple string would do. Soft-delete with view/restore tools when hard delete would be fine for an MVP. This is the kind of spec that gets written when you are thinking about "what if" instead of "what now."

---

## Critical Issues

### 1. Eight Tools Is Absurd

The requirements list eight tool names. That does not mean you need eight tool classes. Look at what we actually have:

```
CreateBoardTool      - Creates a board
UpdateBoardTool      - Updates a board
GetBoardTool         - Reads a board
ListBoardsTool       - Lists boards
DeleteBoardTool      - Soft-deletes a board
RestoreBoardTool     - Restores a deleted board
ViewDeletedBoardsTool - Lists deleted boards
SetActiveBoardTool   - Sets active board
```

The requirements asked for tools. That does not mean one class per tool. You have created 400+ lines of nearly identical boilerplate across eight files. Each tool has the same initializer, the same `find_board` method, the same `error` helper.

**The Fix:** Consolidate into one `WhiteboardTool` class with an `action` parameter, or at most two classes: `BoardTool` for CRUD operations and `ActiveBoardTool` for the context setting.

Even better: follow the pattern of how Rails handles resourceful routes. One controller handles create, update, destroy, show, index. Why should tools be different?

### 2. Soft Delete Is Over-Engineering

The requirements say "soft delete, so it can be restored." This is a nice-to-have that has metastasized into:
- A `deleted_at` column
- An `active` scope and a `deleted` scope
- A `ViewDeletedBoardsTool` class
- A `RestoreBoardTool` class
- Name uniqueness logic that excludes deleted boards
- After-update callbacks to clear active board references

For version 1, just delete the board. If users want it back, they recreate it. The content is in the chat history. This soft-delete ceremony adds three database concerns, two tool classes, and cognitive overhead to every query.

If soft-delete is truly required, add it later when someone actually asks for it in production.

### 3. Polymorphic `last_edited_by` Is Vanity

```ruby
belongs_to :last_edited_by, polymorphic: true, optional: true
```

This exists to answer the question "who last edited this board?" The answer is always going to be an agent, because this is agent-managed shared memory. Users do not have a UI to edit boards. They might someday, but they do not today.

Store `last_edited_by_agent_id`. When you add user editing, add `last_edited_by_user_id`. Or just store a string: `last_edited_by_name`. The polymorphic lookup buys you nothing and costs you a join.

### 4. Too Many Instance Methods on Whiteboard

The `Whiteboard` model has:
- `soft_delete!`
- `restore!`
- `deleted?`
- `content_length`
- `over_recommended_length?`
- `last_edited_at_formatted`
- `last_edited_by_name`
- `update_content!`
- `update_metadata!`
- `for_index`

Half of these exist solely to serve the tool layer's needs. `update_content!` and `update_metadata!` are unused in the spec itself - the tools call `update!` directly. Dead code before it is even written.

`for_index` returns a hash that duplicates `json_attributes`. Pick one approach.

### 5. The Tools Are Not Using The Model Methods

You defined `update_content!` and `update_metadata!` on the model, but the `UpdateBoardTool` does not use them:

```ruby
# In the model:
def update_content!(new_content, editor:)
  update!(content: new_content, last_edited_by: editor, last_edited_at: Time.current)
end

# In the tool (does NOT use update_content!):
updates[:content] = content.to_s.strip if content.present? || content == ""
updates[:last_edited_by] = @current_agent
updates[:last_edited_at] = Time.current
board.update!(updates)
```

This is a code smell. Either the model methods are the right abstraction (use them) or they are not (remove them). Do not have both.

---

## Improvements Needed

### Consolidate Tools

Before:
```
app/tools/create_board_tool.rb
app/tools/update_board_tool.rb
app/tools/get_board_tool.rb
app/tools/list_boards_tool.rb
app/tools/delete_board_tool.rb
app/tools/restore_board_tool.rb
app/tools/view_deleted_boards_tool.rb
app/tools/set_active_board_tool.rb
```

After:
```
app/tools/whiteboard_tool.rb
```

One tool. One file. One param called `action` that accepts: `create`, `update`, `get`, `list`, `delete`, `set_active`. Drop `restore` and `view_deleted` for v1.

```ruby
class WhiteboardTool < RubyLLM::Tool
  description "Manage shared whiteboards. Actions: create, update, get, list, delete, set_active"

  param :action, type: :string,
        desc: "The action to perform: create, update, get, list, delete, set_active",
        required: true

  param :board_id, type: :string,
        desc: "Board ID (required for update, get, delete, set_active)",
        required: false

  param :name, type: :string,
        desc: "Board name (required for create, optional for update)",
        required: false

  param :summary, type: :string,
        desc: "Board summary (required for create, optional for update)",
        required: false

  param :content, type: :string,
        desc: "Board content in markdown",
        required: false

  def initialize(chat: nil, current_agent: nil)
    super()
    @chat = chat
    @agent = current_agent
  end

  def execute(action:, board_id: nil, name: nil, summary: nil, content: nil)
    return error("Requires group conversation") unless @agent && @chat

    case action
    when "create" then create_board(name:, summary:, content:)
    when "update" then update_board(board_id:, name:, summary:, content:)
    when "get"    then get_board(board_id:)
    when "list"   then list_boards
    when "delete" then delete_board(board_id:)
    when "set_active" then set_active_board(board_id)
    else error("Unknown action: #{action}")
    end
  end

  private

  def create_board(name:, summary:, content:)
    return error("Name required") if name.blank?
    return error("Summary required") if summary.blank?

    board = whiteboards.create!(
      name: name.strip,
      summary: summary.strip,
      content: content&.strip,
      last_edited_by: @agent,
      last_edited_at: Time.current
    )
    { success: true, board_id: board.obfuscated_id, name: board.name }
  rescue ActiveRecord::RecordInvalid => e
    error(e.record.errors.full_messages.join(", "))
  end

  def update_board(board_id:, name:, summary:, content:)
    board = find_board(board_id) or return error("Board not found")
    return error("Nothing to update") if name.blank? && summary.blank? && content.nil?

    board.update!(
      **{ name:, summary:, content: }.compact.transform_values(&:strip),
      last_edited_by: @agent,
      last_edited_at: Time.current
    )
    { success: true, board_id: board.obfuscated_id, revision: board.revision }
  rescue ActiveRecord::RecordInvalid => e
    error(e.record.errors.full_messages.join(", "))
  end

  def get_board(board_id:)
    board = find_board(board_id) or return error("Board not found")
    board.as_json(only: [:name, :summary, :content, :revision]).merge(board_id: board.obfuscated_id)
  end

  def list_boards
    boards = whiteboards.by_name.map { |b| { id: b.obfuscated_id, name: b.name, summary: b.summary } }
    { boards:, active_board_id: @chat.active_whiteboard&.obfuscated_id }
  end

  def delete_board(board_id:)
    board = find_board(board_id) or return error("Board not found")
    board.destroy!
    { success: true, deleted: board.name }
  end

  def set_active_board(board_id)
    if board_id.blank? || board_id.to_s.downcase == "none"
      @chat.update!(active_whiteboard: nil)
      return { success: true, message: "Active board cleared" }
    end

    board = find_board(board_id) or return error("Board not found")
    @chat.update!(active_whiteboard: board)
    { success: true, active_board: board.name }
  end

  def whiteboards = @chat.account.whiteboards
  def find_board(id) = whiteboards.find_by_obfuscated_id(id)
  def error(msg) = { error: msg }
end
```

That is 80 lines instead of 400+. One file to maintain. One pattern to understand.

### Simplify The Model

```ruby
class Whiteboard < ApplicationRecord
  include Broadcastable
  include ObfuscatesId

  MAX_RECOMMENDED_LENGTH = 10_000

  belongs_to :account
  belongs_to :last_edited_by, class_name: "Agent", optional: true
  has_many :chats, foreign_key: :active_whiteboard_id, dependent: :nullify

  validates :name, presence: true,
                   length: { maximum: 100 },
                   uniqueness: { scope: :account_id }
  validates :summary, presence: true, length: { maximum: 250 }
  validates :content, length: { maximum: 100_000 }

  broadcasts_to :account

  scope :by_name, -> { order(:name) }

  before_save :increment_revision, if: :content_changed?

  def over_recommended_length?
    content.to_s.length > MAX_RECOMMENDED_LENGTH
  end

  private

  def increment_revision
    self.revision = (revision || 0) + 1
    self.last_edited_at = Time.current
  end
end
```

That is 35 lines instead of 110. No soft-delete. No `for_index`. No `update_content!`. No polymorphism. Just the model.

### Drop These Entirely For V1

1. **Soft delete** - Use hard delete. Restore later if needed.
2. **ViewDeletedBoardsTool** - Gone with soft delete.
3. **RestoreBoardTool** - Gone with soft delete.
4. **Polymorphic last_edited_by** - Just reference Agent.
5. **update_content! and update_metadata!** - Unused abstractions.
6. **for_index method** - Use existing json_attributes or as_json.

---

## What Works Well

1. **The database schema is sound** - The core table structure (name, summary, content, revision) is correct.

2. **Context injection pattern** - Following the existing `memory_context` pattern for `whiteboard_index_context` is the right call.

3. **Active board per conversation** - This is a good design that allows different conversations to focus on different boards.

4. **Scoped to account** - Correct isolation.

5. **The revision tracking concept** - Simple timestamp + revision number is appropriately minimal.

---

## Refactored Implementation Summary

### Database (Two Migrations)

```ruby
# Migration 1: Create whiteboards
class CreateWhiteboards < ActiveRecord::Migration[8.1]
  def change
    create_table :whiteboards do |t|
      t.references :account, null: false, foreign_key: true
      t.string :name, null: false
      t.string :summary, null: false, limit: 250
      t.text :content
      t.integer :revision, null: false, default: 1
      t.references :last_edited_by, foreign_key: { to_table: :agents }
      t.datetime :last_edited_at
      t.timestamps
    end

    add_index :whiteboards, [:account_id, :name], unique: true
  end
end

# Migration 2: Add active_whiteboard to chats
class AddActiveWhiteboardToChats < ActiveRecord::Migration[8.1]
  def change
    add_reference :chats, :active_whiteboard, foreign_key: { to_table: :whiteboards }
  end
end
```

### Model (35 lines)

One model file as shown above.

### Tool (80 lines)

One tool file as shown above.

### Chat Modifications (Add 25 lines)

Add to Chat:
```ruby
belongs_to :active_whiteboard, class_name: "Whiteboard", optional: true

private

def whiteboard_index_context
  boards = account.whiteboards.by_name
  return if boards.empty?

  lines = boards.map do |b|
    warning = b.over_recommended_length? ? " [OVER LIMIT]" : ""
    "- #{b.name} (#{b.content.to_s.length} chars)#{warning}: #{b.summary}"
  end

  "# Shared Whiteboards\n\n#{lines.join("\n")}"
end

def active_whiteboard_context
  return unless active_whiteboard

  "# Active Whiteboard: #{active_whiteboard.name}\n\n#{active_whiteboard.content}"
end
```

Update `system_message_for` to include both contexts.

---

## Final Verdict

Cut 60% of this spec. Ship the simple version. Add soft-delete, polymorphism, and separate tool classes when someone actually needs them - not because they might be nice someday.

The best code is the code you do not write. Right now this spec is writing a lot of code that nobody asked for.

---

*"Complexity is your enemy. Any fool can make something complicated. It is hard to make something simple."* - Richard Branson (but DHH would approve)
