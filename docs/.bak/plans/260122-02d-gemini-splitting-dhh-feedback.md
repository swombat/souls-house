# DHH Review: Gemini Hallucinated Tool Results Spec (v2d)

**Reviewer**: DHH-style code review
**Date**: 2026-01-23
**Verdict**: Not Rails-worthy in its current form

## Overall Assessment

This spec solves a real problem but does so with the wrong level of abstraction. The solution is simultaneously too specific (hardcoded to SaveMemoryTool) and too scattered (logic spread between Message, StreamsAiResponse, and a rake task). The proposed code would not be accepted into Rails core because it conflates parsing, business logic, and presentation in ways that make future maintenance painful.

The core insight is correct: Gemini is hallucinating tool results, and we must execute those tools to preserve user intent. But the implementation treats this as a "fix-up" problem rather than a domain modeling problem.

## Critical Issues

### 1. Class Methods on Message for What Should Be a Concern

```ruby
class << self
  def strip_tool_result_prefix(content)
  def extract_json_prefix(content)
end
```

These are utility methods masquerading as class methods. They have nothing to do with `Message` as a model. They are string parsing operations. This violates the Single Responsibility Principle and clutters the Message model with parsing logic.

### 2. Hardcoding to SaveMemoryTool

The spec explicitly says:

> This spec focuses on `SaveMemoryTool` because it is the most common case

This is precisely backwards. When you discover a pattern, you build the abstraction first, then apply it to the specific case. The proposed `extract_hallucinated_save_memory_args` method is not extensible. When the next tool exhibits this behavior, you will copy-paste-modify.

### 3. Magic Marker in tools_used

```ruby
tools_used: (tools_used || []) + ["save_memory (recovered)"]
```

This is a code smell. You are encoding metadata into a display string. If you need to track that a tool was recovered rather than executed normally, that is a database column, not a string suffix.

### 4. The Rake Task is a Crutch

The rake task exists because the real-time fix happens too late (in `finalize_message!`). This suggests the architecture is fighting you. You are patching after the fact rather than handling the problem at its source.

### 5. Violation of Tell, Do Not Ask

```ruby
if @ai_message.recover_hallucinated_tool_call!
  Rails.logger.info "Recovered hallucinated tool call..."
end
```

The caller is asking the message whether it can recover, then telling it to recover. The message should know what to do and do it.

## Improvements Needed

### Extract a Proper Service Object

The logic of "parse hallucinated tool result, execute tool, clean content" is a single responsibility. It deserves its own object.

**Before (scattered across Message)**:
```ruby
def has_hallucinated_tool_result?
def extract_hallucinated_save_memory_args
def recover_hallucinated_tool_call!
```

**After (single responsibility)**:
```ruby
# app/services/hallucinated_tool_recovery.rb
class HallucinatedToolRecovery
  def initialize(message)
    @message = message
  end

  def call
    return unless recoverable?

    execute_tool
    clean_content
  end

  private

  attr_reader :message

  def recoverable?
    message.assistant? &&
      message.agent_id? &&
      !message.used_tools? &&
      parsed_result&.dig(:success)
  end

  def parsed_result
    @parsed_result ||= parse_leading_json(message.content)
  end

  def execute_tool
    tool_class.new(
      chat: message.chat,
      current_agent: message.agent
    ).execute(**tool_arguments)
  end

  def clean_content
    message.update!(
      content: remaining_content,
      tools_used: [tool_name]
    )
  end
end
```

### Build an Extensible Tool Detection System

Instead of `extract_hallucinated_save_memory_args`, build a registry.

```ruby
class HallucinatedToolRecovery
  RECOVERABLE_TOOLS = {
    ->(data) { data[:success] && data[:memory_type] && data[:content] } => {
      tool: SaveMemoryTool,
      arguments: ->(data) { { content: data[:content], memory_type: data[:memory_type] } }
    }
    # Add more tools here as needed
  }.freeze

  def recoverable_tool
    RECOVERABLE_TOOLS.find { |detector, _| detector.call(parsed_result) }&.last
  end
end
```

### Move JSON Parsing to a Concern

```ruby
# app/models/concerns/parses_json_prefix.rb
module ParsesJsonPrefix
  extend ActiveSupport::Concern

  class_methods do
    def extract_json_prefix(text)
      return nil if text.blank?

      text = text.to_s.lstrip
      return nil unless text.start_with?("{")

      depth = 0
      text.each_char.with_index do |char, i|
        depth += 1 if char == "{"
        depth -= 1 if char == "}"
        return text[0..i] if depth.zero?
      end

      nil
    end
  end
end
```

### The Integration Should Be Simple

```ruby
# In finalize_message!
def finalize_message!(ruby_llm_message)
  # ... existing code ...

  @ai_message.update!(...)

  HallucinatedToolRecovery.new(@ai_message).call

  ModerateMessageJob.perform_later(@ai_message) if @ai_message.content.present?
end
```

One line. No conditionals. The service object knows whether it should act.

## What Works Well

1. **The problem analysis is excellent.** You correctly identified that Gemini is hallucinating tool results, that `tools_used` is empty, and that simply stripping JSON would lose data. This investigation was thorough.

2. **The transaction wrapper in recover_hallucinated_tool_call!** ensures atomicity. Good instinct.

3. **The dry-run rake task** is a good practice for data migrations.

4. **The test cases are comprehensive** and cover edge cases appropriately.

## Refactored Architecture

Here is how I would structure this:

```
app/
  models/
    concerns/
      parses_json_prefix.rb           # Extracted JSON parsing
  services/
    hallucinated_tool_recovery.rb     # Main service object
    hallucinated_tool_recovery/
      save_memory_recoverer.rb        # Specific to SaveMemoryTool
```

```ruby
# app/services/hallucinated_tool_recovery.rb
class HallucinatedToolRecovery
  include ParsesJsonPrefix

  RECOVERERS = [
    HallucinatedToolRecovery::SaveMemoryRecoverer
  ].freeze

  def initialize(message)
    @message = message
  end

  def call
    return unless candidate?

    recoverer = RECOVERERS.find { |r| r.matches?(parsed_result) }
    return unless recoverer

    recoverer.new(@message, parsed_result).recover!
  end

  private

  def candidate?
    @message.role == "assistant" &&
      @message.agent_id.present? &&
      !@message.used_tools? &&
      parsed_result.present?
  end

  def parsed_result
    @parsed_result ||= begin
      json_str = self.class.extract_json_prefix(@message.content)
      return nil unless json_str
      JSON.parse(json_str, symbolize_names: true)
    rescue JSON::ParserError
      nil
    end
  end
end
```

```ruby
# app/services/hallucinated_tool_recovery/save_memory_recoverer.rb
class HallucinatedToolRecovery::SaveMemoryRecoverer
  def self.matches?(data)
    data[:success] == true &&
      data[:content].present? &&
      data[:memory_type].present? &&
      AgentMemory.memory_types.key?(data[:memory_type])
  end

  def initialize(message, parsed_result)
    @message = message
    @parsed_result = parsed_result
  end

  def recover!
    Message.transaction do
      create_memory!
      clean_message!
    end
  end

  private

  def create_memory!
    @message.agent.memories.create!(
      content: @parsed_result[:content].to_s.strip,
      memory_type: @parsed_result[:memory_type]
    )
  end

  def clean_message!
    remaining = @message.content.sub(/\A\s*\{[^}]*\}\s*/m, "")
    @message.update!(
      content: remaining.strip,
      tools_used: ["save_memory"]
    )
  end
end
```

## Final Verdict

The spec correctly identifies the problem and the general solution. However, the implementation does not meet the bar for Rails-worthy code because:

1. It scatters logic across too many places
2. It hardcodes to a single tool rather than building an extensible pattern
3. It pollutes the Message model with parsing utilities
4. It uses string markers where database columns belong

Refactor to use a service object with a registry of recoverers. The Message model should remain focused on being a message. The recovery logic should live in its own object that can be tested, extended, and understood in isolation.

The goal is code that would make sense to a new developer reading it for the first time. "Oh, there is a HallucinatedToolRecovery service that handles Gemini's tendency to fake tool results. Each tool that can be recovered has its own recoverer class." That is a story. The current spec reads like a patch.

---

**Recommendation**: Revise the spec to use a service object pattern before implementation.
