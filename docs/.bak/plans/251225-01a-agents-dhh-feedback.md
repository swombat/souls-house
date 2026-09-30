# DHH Code Review: Agents Feature Implementation Spec

**Reviewer:** DHH-style review
**Document:** 251225-01a-agents.md
**Date:** 2025-12-25
**Verdict:** Not Rails-worthy in its current form. Significant bloat detected.

---

## Overall Assessment

This spec suffers from a classic case of over-engineering. It takes what should be a simple CRUD resource and inflates it with unnecessary complexity. The core idea is sound - agents are account-scoped records with a name, system prompt, model selection, and tool configuration. That is a *simple* model. Yet the spec proposes four Svelte pages, a reusable form component, and a separate show page that serves no practical purpose.

The good news: the Rails patterns are mostly correct. The bad news: there is too much of everything. This feels like enterprise software design, not Rails craftsmanship.

---

## Critical Issues

### 1. The `show` Page is Pointless

The spec includes a dedicated `show.svelte` page (Step 12) that displays agent details in read-only mode with an "Edit Agent" button. This is bureaucratic nonsense.

**Why does this exist?** A user clicks on an agent to... see a read-only view... then clicks another button to edit? Just go straight to edit. Or combine index and show like the existing chats do.

**Cut it entirely.** The index page already shows agent details in cards. If someone wants to see more, they click Edit.

### 2. The Form Component is Premature Abstraction

Step 10 creates `AgentForm.svelte` as a "reusable" component for new and edit pages. But reusable by whom? It is used exactly twice - in new and edit. This is textbook premature abstraction.

**The Rails Way:** Put the form directly in each page. Yes, there will be some duplication. That is fine. When you have *three* places using the same form, extract. Two is not a pattern, it is a coincidence.

Looking at the existing codebase, `chats/new.svelte` does not extract a `ChatForm` component. It just has the form inline. Follow that pattern.

### 3. Dual Model ID Columns - Confusing

The migration has both `model_id_string` and `ai_model_id`:

```ruby
t.string :model_id_string, null: false, default: "openrouter/auto"
t.references :ai_model, foreign_key: true
```

This mirrors the Chat model, but is it necessary for Agents? The Chat model has this because of RubyLLM's `acts_as_chat` integration which requires the association. Agents do not use `acts_as_chat`.

**Simplify:** Just use `model_id_string`. Drop the `ai_model_id` reference unless there is a concrete future need. YAGNI.

### 4. Tool Discovery Caching - Over-Engineered

```ruby
def self.available_tools
  @available_tools ||= discover_tools
end

def self.reset_tool_cache!
  @available_tools = nil
end
```

This class-level caching with a reset method screams "I am thinking about testing problems that do not exist yet." The tool discovery reads a few files from disk once per request (at most). Rails already caches classes in production.

**Simplify:** Just call `discover_tools` directly. If performance becomes an issue (it will not), add caching then.

### 5. GIN Index on JSONB - Premature Optimization

```ruby
add_index :agents, :enabled_tools, using: :gin
```

When will you ever query "find all agents with tool X enabled"? This is a GIN index for a query pattern that does not exist. The enabled_tools array is only ever read when configuring an agent's response, never searched.

**Cut it.** Add indexes when you have slow queries, not before.

---

## Improvements Needed

### Database Migration

Remove unnecessary complexity:

```ruby
# BEFORE (over-engineered)
t.string :model_id_string, null: false, default: "openrouter/auto"
t.references :ai_model, foreign_key: true
t.jsonb :enabled_tools, null: false, default: []
t.boolean :active, null: false, default: true
add_index :agents, :enabled_tools, using: :gin

# AFTER (right-sized)
t.string :model_id, null: false, default: "openrouter/auto"
t.jsonb :enabled_tools, null: false, default: []
t.boolean :active, null: false, default: true
# No GIN index - we never search by tools
```

### Agent Model

Simplify tool discovery and naming:

```ruby
# BEFORE
MODELS = Chat::MODELS  # Coupling to Chat

def self.available_tools
  @available_tools ||= discover_tools
end

def model_id
  model_id_string
end

# AFTER
def self.available_tools
  Dir[Rails.root.join("app/tools/*_tool.rb")].filter_map do |file|
    File.basename(file, ".rb").camelize.constantize
  rescue NameError
    nil
  end
end

def model_id
  read_attribute(:model_id)
end
```

Note: Sharing `MODELS` with Chat is fine, but consider whether agents truly need the same model list. Perhaps extract to a shared module if both need it.

### Controller - Too Many Props

The controller passes `account: current_account.as_json` to every action. Is the full account JSON really needed? Looking at how it is used in the Svelte pages, it is only for `account.id` in path helpers.

```ruby
# BEFORE
render inertia: "agents/index", props: {
  agents: @agents.as_json,
  account: current_account.as_json  # Full account object
}

# AFTER
render inertia: "agents/index", props: {
  agents: @agents.as_json,
  account_id: current_account.id  # Just the ID
}
```

Actually, looking at the existing patterns, the codebase does pass `account: current_account.as_json` elsewhere. Keep it for consistency, but this is worth revisiting across the codebase later.

### Frontend - Eliminate Three Files

**Cut these files entirely:**

1. `agents/show.svelte` - Pointless read-only view
2. `lib/components/agents/AgentForm.svelte` - Premature extraction

**Combine new and edit:**

The difference between new and edit is minimal:
- Whether `agent` prop exists
- The submit URL and method
- The page title

This can be one component with conditional logic, or two simple pages without a shared form component. Looking at the existing `chats/` pages, they use `chats/new.svelte` for both creating and the index view. Follow that pattern.

### Proposed Svelte Structure

```
app/frontend/pages/agents/
  index.svelte    # List agents with inline create/edit modals or expandable cards
  edit.svelte     # Edit form (could reuse for new with empty agent)
```

Or even simpler:

```
app/frontend/pages/agents/
  index.svelte    # Everything: list, create modal, edit modal
```

One file, complete feature. This is how `chats/new.svelte` works - it shows the chat list AND allows creating new chats.

---

## What Works Well

1. **RESTful routing** - Nested under accounts, standard CRUD. Correct.

2. **Association-based authorization** - `current_account.agents.find(params[:id])`. This is the Rails way.

3. **Feature gating with `require_feature_enabled`** - Follows established pattern.

4. **JSONB for enabled_tools** - Correct choice over a join table. Simple arrays belong in JSONB, not normalized tables.

5. **Broadcasts and concerns** - Proper use of existing Broadcastable, ObfuscatesId patterns.

6. **Audit logging** - Following established patterns for create/update/destroy.

7. **Validation logic** - Clean, model-level validations with custom validator for tools.

---

## Refactored Approach

### Minimal Viable Implementation

**One migration:**
```ruby
create_table :agents do |t|
  t.references :account, null: false, foreign_key: true
  t.string :name, null: false
  t.text :system_prompt
  t.string :model_id, null: false, default: "openrouter/auto"
  t.jsonb :enabled_tools, null: false, default: []
  t.boolean :active, null: false, default: true
  t.timestamps
end

add_index :agents, [:account_id, :name], unique: true
add_index :agents, [:account_id, :active]
```

**One model** (simplified):
```ruby
class Agent < ApplicationRecord
  include Broadcastable
  include ObfuscatesId
  include JsonAttributes
  include SyncAuthorizable

  belongs_to :account

  validates :name, presence: true,
                   length: { maximum: 100 },
                   uniqueness: { scope: :account_id }
  validates :system_prompt, length: { maximum: 50_000 }
  validate :enabled_tools_must_be_valid

  broadcasts_to :account

  scope :active, -> { where(active: true) }
  scope :by_name, -> { order(:name) }

  json_attributes :name, :system_prompt, :model_id, :model_name,
                  :enabled_tools, :active?

  def self.available_tools
    Dir[Rails.root.join("app/tools/*_tool.rb")].filter_map do |file|
      File.basename(file, ".rb").camelize.constantize
    rescue NameError
      nil
    end
  end

  def tools
    return [] if enabled_tools.blank?
    enabled_tools.filter_map { |name| name.constantize rescue nil }
  end

  def model_name
    Chat::MODELS.find { |m| m[:model_id] == model_id }&.dig(:label) || model_id
  end

  private

  def enabled_tools_must_be_valid
    return if enabled_tools.blank?
    available = self.class.available_tools.map(&:name)
    invalid = enabled_tools - available
    errors.add(:enabled_tools, "contains invalid tools: #{invalid.join(', ')}") if invalid.any?
  end
end
```

**One controller** (four actions, not seven):
```ruby
class AgentsController < ApplicationController
  require_feature_enabled :agents
  before_action :set_agent, only: [:edit, :update, :destroy]

  def index
    @agents = current_account.agents.by_name
    render inertia: "agents/index", props: {
      agents: @agents.as_json,
      models: Chat::MODELS,
      available_tools: tools_for_frontend,
      account: current_account.as_json
    }
  end

  def create
    @agent = current_account.agents.new(agent_params)
    if @agent.save
      audit("create_agent", @agent, **agent_params.to_h)
      redirect_to account_agents_path(current_account), notice: "Agent created"
    else
      redirect_to account_agents_path(current_account),
                  inertia: { errors: @agent.errors.to_hash }
    end
  end

  def edit
    render inertia: "agents/edit", props: {
      agent: @agent.as_json,
      models: Chat::MODELS,
      available_tools: tools_for_frontend,
      account: current_account.as_json
    }
  end

  def update
    if @agent.update(agent_params)
      audit("update_agent", @agent, **agent_params.to_h)
      redirect_to account_agents_path(current_account), notice: "Agent updated"
    else
      redirect_to edit_account_agent_path(current_account, @agent),
                  inertia: { errors: @agent.errors.to_hash }
    end
  end

  def destroy
    audit("destroy_agent", @agent)
    @agent.destroy!
    redirect_to account_agents_path(current_account), notice: "Agent deleted"
  end

  private

  def set_agent
    @agent = current_account.agents.find(params[:id])
  end

  def agent_params
    params.require(:agent).permit(:name, :system_prompt, :model_id, :active, enabled_tools: [])
  end

  def tools_for_frontend
    Agent.available_tools.map do |tool|
      { class_name: tool.name, name: tool.name.underscore.humanize.sub(/ tool$/i, ""), description: tool.try(:description) }
    end
  end
end
```

Note: Removed `new` and `show` actions. The index page handles new agent creation via a modal or inline form.

**Two Svelte files** (not five):
1. `agents/index.svelte` - List with create modal
2. `agents/edit.svelte` - Edit page (or could be a modal from index)

---

## Summary of Cuts

| Item | Action | Reason |
|------|--------|--------|
| `agents/show.svelte` | DELETE | Pointless intermediary page |
| `agents/new.svelte` | DELETE | Merge into index with modal |
| `AgentForm.svelte` | DELETE | Premature abstraction |
| `ai_model_id` column | DELETE | YAGNI - not using acts_as_chat |
| GIN index on enabled_tools | DELETE | No query pattern exists |
| Tool cache reset method | DELETE | Over-engineering |
| `show` controller action | DELETE | No show page |
| `new` controller action | DELETE | Create handles this |

**Lines of code saved:** Approximately 400+ lines across Svelte and the controller.

---

## Final Verdict

The spec demonstrates understanding of Rails patterns but applies them with enterprise-level ceremony. Strip it down. A well-designed agent CRUD should be:

- 1 migration
- 1 model (~50 lines)
- 1 controller (~60 lines)
- 2 Svelte pages (index with create modal, edit page)

Total: ~300-400 lines for the complete feature, not the 800+ implied by the current spec.

Remember: The goal is not to build a cathedral. The goal is to ship software that works and can be understood by anyone opening the codebase for the first time. Simple, obvious, boring. That is Rails-worthy code.
