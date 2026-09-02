require "test_helper"

class ChatTest < ActiveSupport::TestCase

  def setup
    @user = User.create!(
      email_address: "test#{SecureRandom.hex(4)}@example.com",
      password: "password123"
    )
    @user.profile.update!(first_name: "Test", last_name: "User")
    @account = @user.personal_account
    @account.update!(use_system_ai_credentials: true)
  end

  test "belongs to account" do
    chat = Chat.create!(account: @account)
    assert_equal @account, chat.account
  end

  test "has many messages with destroy dependency" do
    chat = Chat.create!(account: @account)
    message = chat.messages.create!(
      user: @user,
      role: "user",
      content: "Test message"
    )
    message_id = message.id

    chat.destroy!

    assert_not Message.exists?(message_id)
  end

  test "model_id always has a value due to database default" do
    # With the database default on model_id_string column and after_initialize callback,
    # a chat always has a model_id. This is the expected behavior for RubyLLM 1.9+
    chat = Chat.new(account: @account)

    assert chat.valid?
    assert_equal "openrouter/auto", chat.model_id
  end

  test "defaults model_id to openrouter/auto" do
    chat = Chat.create!(account: @account)
    assert_equal "openrouter/auto", chat.model_id
  end

  test "schedules title generation job after create when no title" do
    assert_enqueued_with(job: GenerateTitleJob) do
      Chat.create!(account: @account)
    end
  end

  test "does not schedule title generation when title exists" do
    assert_no_enqueued_jobs(only: GenerateTitleJob) do
      Chat.create!(account: @account, title: "Existing Title")
    end
  end

  test "includes required concerns" do
    assert Chat.included_modules.include?(Broadcastable)
    assert Chat.included_modules.include?(ObfuscatesId)
    assert Chat.included_modules.include?(Discard::Model)
  end

  test "acts as chat" do
    chat = Chat.create!(account: @account)
    # RubyLLM methods should be available
    assert chat.respond_to?(:ask)
    # Note: generate_title is not a direct method, it's handled by the job
    assert chat.respond_to?(:to_llm)
  end

  test "builds direct-provider chat for models missing from RubyLLM registry" do
    chat = Chat.create!(
      account: @account,
      model_id: "openai/gpt-5.6-sol",
      title: "Future model"
    )

    assert_nothing_raised { chat.to_llm }
  end

  test "broadcasts to account" do
    assert_equal [ :account ], Chat.broadcast_targets
  end

  test "create_with_message! creates chat and message" do
    assert_difference "Chat.count" do
      assert_difference "Message.count" do
        assert_enqueued_with(job: AiResponseJob) do
          @chat = Chat.create_with_message!(
            { model_id: "gpt-4o", account: @account },
            message_content: "Hello AI",
            user: @user
          )
        end
      end
    end

    message = @chat.messages.last
    assert_equal "Hello AI", message.content
    assert_equal "user", message.role
    assert_equal @user, message.user
  end

  test "create_with_message! creates chat without message when content is blank" do
    assert_difference "Chat.count" do
      assert_no_difference "Message.count" do
        assert_no_enqueued_jobs(only: AiResponseJob) do
          @chat = Chat.create_with_message!(
            { model_id: "gpt-4o", account: @account },
            message_content: nil,
            user: @user
          )
        end
      end
    end
  end

  test "create_with_message! creates chat and message with file attachments" do
    # Create test file
    file = Rack::Test::UploadedFile.new(
      Rails.root.join("test/fixtures/files/test_image.png"),
      "image/png"
    )

    assert_difference "Chat.count" do
      assert_difference "Message.count" do
        assert_enqueued_with(job: AiResponseJob) do
          @chat = Chat.create_with_message!(
            { model_id: "gpt-4o", account: @account },
            message_content: "Here's an image",
            user: @user,
            files: [ file ]
          )
        end
      end
    end

    message = @chat.messages.last
    assert_equal "Here's an image", message.content
    assert_equal "user", message.role
    assert_equal @user, message.user

    # This should pass but might currently fail
    assert message.attachments.attached?, "Files should be attached to the message"
    assert_equal 1, message.attachments.count
    assert_equal "test_image.png", message.attachments.first.filename.to_s
  end

  test "create_with_message! creates chat with only files (no content)" do
    file = Rack::Test::UploadedFile.new(
      Rails.root.join("test/fixtures/files/test_image.png"),
      "image/png"
    )

    assert_difference "Chat.count" do
      assert_difference "Message.count" do
        assert_enqueued_with(job: AiResponseJob) do
          @chat = Chat.create_with_message!(
            { model_id: "gpt-4o", account: @account },
            message_content: nil,
            user: @user,
            files: [ file ]
          )
        end
      end
    end

    message = @chat.messages.last
    assert_equal "", message.content
    assert_equal "user", message.role
    assert message.attachments.attached?
  end

  test "title_or_default returns title when present" do
    chat = Chat.create!(account: @account, title: "My Chat")
    assert_equal "My Chat", chat.title_or_default
  end

  test "title_or_default returns default when title is blank" do
    chat = Chat.create!(account: @account)
    assert_equal "New Conversation", chat.title_or_default
  end

  test "ai_model_name returns correct model name" do
    chat = Chat.create!(account: @account, model_id: "openai/gpt-4o-mini")
    assert_equal "GPT-4o Mini", chat.ai_model_name
  end

  test "ai_model_name returns nil for unknown model" do
    chat = Chat.create!(account: @account, model_id: "unknown/model")
    assert_nil chat.ai_model_name
  end

  test "updated_at_formatted returns formatted date" do
    chat = Chat.create!(account: @account)
    # Use a time that accounts for potential timezone differences
    time = Time.parse("2024-01-15 14:30:00 UTC")
    chat.update!(updated_at: time)
    # Test the format without being specific about timezone
    formatted = chat.updated_at_formatted
    assert_includes formatted, "Jan 15 at"
    assert_includes formatted, ":30"
    assert_includes formatted, "M" # AM or PM
  end

  test "updated_at_short returns short date" do
    chat = Chat.create!(account: @account)
    chat.update!(updated_at: Time.new(2024, 1, 15, 14, 30, 0))
    assert_equal "Jan 15", chat.updated_at_short
  end

  test "message_count returns correct count" do
    chat = Chat.create!(account: @account)
    assert_equal 0, chat.message_count

    chat.messages.create!(content: "Test", role: "user", user: @user)
    assert_equal 1, chat.reload.message_count

    chat.messages.create!(content: "Response", role: "assistant")
    assert_equal 2, chat.reload.message_count
  end

  test "as_json returns default format" do
    chat = Chat.create!(account: @account, title: "Test Chat", model_id: "gpt-4o")
    chat.messages.create!(content: "Test", role: "user", user: @user)

    json = chat.as_json

    assert_equal chat.to_param, json["id"]
    assert_equal "Test Chat", json["title_or_default"]
    assert_equal "gpt-4o", json["model_id"]
    assert_nil json["ai_model_name"] # Unknown model
    assert_equal 1, json["message_count"]
    assert json["updated_at_formatted"].present?
  end

  test "as_json returns sidebar format" do
    chat = Chat.create!(account: @account, title: "Sidebar Chat")

    json = chat.as_json(as: :sidebar_json)

    assert_equal chat.to_param, json["id"]
    assert_equal "Sidebar Chat", json["title_or_default"]
    assert json["updated_at_short"].present?
    assert_equal 0, json["message_count"]
    assert_equal false, json["manual_responses"]

    # Should not include other fields
    assert_nil json["model_id"]
    assert_nil json["ai_model_name"]
    assert_nil json["updated_at_formatted"]
  end

  test "web_access defaults to false" do
    chat = Chat.create!(account: @account)
    assert_equal false, chat.web_access
  end

  test "available_tools returns empty array when web fetch disabled" do
    chat = Chat.create!(account: @account, web_access: false)
    assert_empty chat.available_tools
  end

  test "available_tools stays empty when legacy web access is enabled" do
    chat = Chat.create!(account: @account, web_access: true)
    assert_empty chat.available_tools
  end

  test "web_access can be set on create" do
    chat = Chat.create!(account: @account, web_access: true)
    assert chat.web_access
  end

  test "web_access can be updated" do
    chat = Chat.create!(account: @account, web_access: false)
    assert_not chat.web_access

    chat.update!(web_access: true)
    assert chat.web_access
  end

  # Archive functionality tests

  test "archive! sets archived_at to current time" do
    chat = Chat.create!(account: @account)
    assert_nil chat.archived_at

    freeze_time do
      chat.archive!
      assert_equal Time.current, chat.archived_at
    end
  end

  test "unarchive! sets archived_at to nil" do
    chat = Chat.create!(account: @account)
    chat.archive!
    assert chat.archived?

    chat.unarchive!
    assert_nil chat.archived_at
    assert_not chat.archived?
  end

  test "archived? returns true when archived_at is present" do
    chat = Chat.create!(account: @account)
    assert_not chat.archived?

    chat.archive!
    assert chat.archived?
  end

  test "archived? returns false when archived_at is nil" do
    chat = Chat.create!(account: @account)
    assert_not chat.archived?
  end

  # Discard functionality tests (soft delete)

  test "discard! sets discarded_at" do
    chat = Chat.create!(account: @account)
    assert_nil chat.discarded_at

    chat.discard!
    assert chat.discarded_at.present?
    assert chat.discarded?
  end

  test "undiscard! clears discarded_at" do
    chat = Chat.create!(account: @account)
    chat.discard!
    assert chat.discarded?

    chat.undiscard!
    assert_nil chat.discarded_at
    assert_not chat.discarded?
  end

  test "kept scope excludes discarded chats" do
    chat1 = Chat.create!(account: @account, title: "Active Chat")
    chat2 = Chat.create!(account: @account, title: "Discarded Chat")
    chat2.discard!

    kept_chats = @account.chats.kept
    assert_includes kept_chats, chat1
    assert_not_includes kept_chats, chat2
  end

  test "with_discarded scope includes discarded chats" do
    chat1 = Chat.create!(account: @account, title: "Active Chat")
    chat2 = Chat.create!(account: @account, title: "Discarded Chat")
    chat2.discard!

    all_chats = @account.chats.with_discarded
    assert_includes all_chats, chat1
    assert_includes all_chats, chat2
  end

  # Archive scopes tests

  test "archived scope returns only archived chats" do
    active_chat = Chat.create!(account: @account, title: "Active Chat")
    archived_chat = Chat.create!(account: @account, title: "Archived Chat")
    archived_chat.archive!

    archived_chats = @account.chats.archived
    assert_includes archived_chats, archived_chat
    assert_not_includes archived_chats, active_chat
  end

  test "active scope returns only non-archived chats" do
    active_chat = Chat.create!(account: @account, title: "Active Chat")
    archived_chat = Chat.create!(account: @account, title: "Archived Chat")
    archived_chat.archive!

    active_chats = @account.chats.active
    assert_includes active_chats, active_chat
    assert_not_includes active_chats, archived_chat
  end

  # Respondable tests

  test "respondable? returns true for active non-discarded chat" do
    chat = Chat.create!(account: @account)
    assert chat.respondable?
  end

  test "respondable? returns false for archived chat" do
    chat = Chat.create!(account: @account)
    chat.archive!
    assert_not chat.respondable?
  end

  test "respondable? returns false for discarded chat" do
    chat = Chat.create!(account: @account)
    chat.discard!
    assert_not chat.respondable?
  end

  test "respondable? returns false for archived and discarded chat" do
    chat = Chat.create!(account: @account)
    chat.archive!
    chat.discard!
    assert_not chat.respondable?
  end

  # JSON attributes include archive/discard fields

  test "as_json includes archive and discard fields" do
    chat = Chat.create!(account: @account, title: "Test Chat")

    json = chat.as_json

    assert_includes json.keys, "archived_at"
    assert_includes json.keys, "discarded_at"
    assert_includes json.keys, "archived"
    assert_includes json.keys, "discarded"
    assert_includes json.keys, "respondable"

    assert_nil json["archived_at"]
    assert_nil json["discarded_at"]
    assert_equal false, json["archived"]
    assert_equal false, json["discarded"]
    assert_equal true, json["respondable"]
  end

  test "as_json reflects archived state correctly" do
    chat = Chat.create!(account: @account, title: "Test Chat")
    chat.archive!

    json = chat.as_json

    assert json["archived_at"].present?
    assert_equal true, json["archived"]
    assert_equal false, json["respondable"]
  end

  test "as_json reflects discarded state correctly" do
    chat = Chat.create!(account: @account, title: "Test Chat")
    chat.discard!

    # Need to reload from with_discarded since default scope excludes discarded
    chat = @account.chats.with_discarded.find(chat.id)
    json = chat.as_json

    assert json["discarded_at"].present?
    assert_equal true, json["discarded"]
    assert_equal false, json["respondable"]
  end

  # Pagination tests

  test "messages_page returns limited messages" do
    chat = Chat.create!(account: @account)
    10.times { |i| chat.messages.create!(content: "Message #{i}", role: "user", user: @user) }

    page = chat.messages_page(limit: 5)

    # messages_page returns an Array after .reverse
    assert_equal 5, page.size
    # Verify we got the most recent 5 messages (messages 5-9)
    assert_equal "Message 5", page.first.content
    assert_equal "Message 9", page.last.content
  end

  test "messages_page returns messages in ascending order for display" do
    chat = Chat.create!(account: @account)
    10.times { |i| chat.messages.create!(content: "Message #{i}", role: "user", user: @user) }

    page = chat.messages_page(limit: 5)

    # Messages should be in ascending order (oldest of the recent 5 first)
    assert page.first.id < page.last.id
  end

  test "messages_page with before_id returns older messages" do
    chat = Chat.create!(account: @account)
    messages = 10.times.map { |i| chat.messages.create!(content: "Message #{i}", role: "user", user: @user) }
    middle = messages[5]

    page = chat.messages_page(before_id: middle.to_param, limit: 5)

    # All returned messages should have IDs less than the middle message
    assert page.all? { |m| m.id < middle.id }
    # Should get messages 1-5 (the 5 most recent before message 5)
    assert_equal 5, page.size
  end

  test "messages_page returns empty when before_id is first message" do
    chat = Chat.create!(account: @account)
    first_message = chat.messages.create!(content: "First", role: "user", user: @user)
    chat.messages.create!(content: "Second", role: "user", user: @user)

    page = chat.messages_page(before_id: first_message.to_param)

    assert_empty page
  end

  test "messages_page default limit is 30" do
    chat = Chat.create!(account: @account)
    50.times { |i| chat.messages.create!(content: "Message #{i}", role: "user", user: @user) }

    page = chat.messages_page

    assert_equal 30, page.size
    # Should get the 30 most recent (messages 20-49)
    assert_equal "Message 20", page.first.content
    assert_equal "Message 49", page.last.content
  end

test "cost_tokens sums input and output tokens separately" do
  chat = Chat.create!(account: @account)
  chat.messages.create!(content: "Hello", role: "user", user: @user, input_tokens: 10, output_tokens: 0)
  chat.messages.create!(content: "Hi there", role: "assistant", input_tokens: 0, output_tokens: 20)

  assert_equal({ input: 10, output: 20 }, chat.cost_tokens)
end

test "cost_tokens handles nil values" do
  chat = Chat.create!(account: @account)
  chat.messages.create!(content: "Hello", role: "user", user: @user, input_tokens: nil, output_tokens: nil)

  assert_equal({ input: 0, output: 0 }, chat.cost_tokens)
end

test "cost_tokens returns zero for chat with no messages" do
  chat = Chat.create!(account: @account)

  assert_equal({ input: 0, output: 0 }, chat.cost_tokens)
end

test "cost_tokens sums all message tokens correctly" do
  chat = Chat.create!(account: @account)
  chat.messages.create!(content: "Message 1", role: "user", user: @user, input_tokens: 100, output_tokens: 50)
  chat.messages.create!(content: "Message 2", role: "assistant", input_tokens: 200, output_tokens: 300)
  chat.messages.create!(content: "Message 3", role: "user", user: @user, input_tokens: 150, output_tokens: nil)

  assert_equal({ input: 450, output: 350 }, chat.cost_tokens)
end

test "context_tokens returns max input_tokens across last 10 assistant turns" do
  chat = Chat.create!(account: @account)
  chat.messages.create!(content: "User msg", role: "user", user: @user, input_tokens: 999)
  chat.messages.create!(content: "A", role: "assistant", input_tokens: 100, output_tokens: 10)
  chat.messages.create!(content: "B", role: "assistant", input_tokens: 250, output_tokens: 10)
  chat.messages.create!(content: "C", role: "assistant", input_tokens: 175, output_tokens: 10)

  assert_equal 250, chat.context_tokens
end

test "context_tokens returns 0 when no assistant turns exist" do
  chat = Chat.create!(account: @account)
  chat.messages.create!(content: "Hi", role: "user", user: @user, input_tokens: 50)

  assert_equal 0, chat.context_tokens
end

test "reasoning_tokens sums thinking_tokens, treating nils as zero" do
  chat = Chat.create!(account: @account)
  chat.messages.create!(content: "A", role: "assistant", thinking_tokens: 100)
  chat.messages.create!(content: "B", role: "assistant", thinking_tokens: nil)
  chat.messages.create!(content: "C", role: "assistant", thinking_tokens: 250)

  assert_equal 350, chat.reasoning_tokens
end

test "as_json includes context_tokens, cost_tokens, reasoning_tokens but not total_tokens" do
  chat = Chat.create!(account: @account)
  chat.messages.create!(content: "Hello", role: "user", user: @user, input_tokens: 100, output_tokens: 50)
  chat.messages.create!(content: "Reply", role: "assistant", input_tokens: 200, output_tokens: 75, thinking_tokens: 30)

  json = chat.as_json

  assert_includes json.keys, "context_tokens"
  assert_includes json.keys, "cost_tokens"
  assert_includes json.keys, "reasoning_tokens"
  refute_includes json.keys, "total_tokens"

  assert_equal 200, json["context_tokens"]
  assert_equal 30, json["reasoning_tokens"]
end

test "Chat does not respond to :thinking_compatible_for? or :total_tokens" do
  chat = Chat.create!(account: @account)
  refute chat.respond_to?(:thinking_compatible_for?)
  refute chat.respond_to?(:total_tokens)
end

  # Auto-trigger mentioned agents tests

  test "trigger_mentioned_agents! does nothing for non-group chat" do
    chat = Chat.create!(account: @account, model_id: "openrouter/auto")

    assert_no_enqueued_jobs(only: AllAgentsResponseJob) do
      chat.trigger_mentioned_agents!("Hello Claude")
    end
  end

  test "trigger_mentioned_agents! does nothing for blank content" do
    agent = @account.agents.create!(name: "Claude", system_prompt: "Test")
    chat = @account.chats.new(model_id: "openrouter/auto", manual_responses: true)
    chat.agent_ids = [ agent.id ]
    chat.save!

    assert_no_enqueued_jobs(only: AllAgentsResponseJob) do
      chat.trigger_mentioned_agents!("")
      chat.trigger_mentioned_agents!(nil)
    end
  end

  test "trigger_mentioned_agents! enqueues job for @mentioned agent" do
    agent = @account.agents.create!(name: "Grok", system_prompt: "Test")
    chat = @account.chats.new(model_id: "openrouter/auto", manual_responses: true)
    chat.agent_ids = [ agent.id ]
    chat.save!

    assert_enqueued_with(job: AllAgentsResponseJob, args: [ chat, [ agent.id ] ]) do
      chat.trigger_mentioned_agents!("Hey @Grok, what do you think?")
    end
  end

  test "trigger_mentioned_agents! does not trigger without @ prefix" do
    agent = @account.agents.create!(name: "Grok", system_prompt: "Test")
    chat = @account.chats.new(model_id: "openrouter/auto", manual_responses: true)
    chat.agent_ids = [ agent.id ]
    chat.save!

    assert_no_enqueued_jobs(only: AllAgentsResponseJob) do
      chat.trigger_mentioned_agents!("Hey Grok, what do you think?")
    end
  end

  test "trigger_mentioned_agents! uses word boundaries after @" do
    agent = @account.agents.create!(name: "Grok", system_prompt: "Test")
    chat = @account.chats.new(model_id: "openrouter/auto", manual_responses: true)
    chat.agent_ids = [ agent.id ]
    chat.save!

    assert_no_enqueued_jobs(only: AllAgentsResponseJob) do
      chat.trigger_mentioned_agents!("I'm @groking this concept")
    end
  end

  test "trigger_mentioned_agents! detects multiple @mentioned agents and excludes unmentioned" do
    agent1 = @account.agents.create!(name: "Grok", system_prompt: "Test")
    agent2 = @account.agents.create!(name: "Claude", system_prompt: "Test")
    agent3 = @account.agents.create!(name: "Wing", system_prompt: "Test")
    chat = @account.chats.new(model_id: "openrouter/auto", manual_responses: true)
    chat.agent_ids = [ agent1.id, agent2.id, agent3.id ]
    chat.save!

    assert_enqueued_with(job: AllAgentsResponseJob) do
      chat.trigger_mentioned_agents!("Hey @Grok and @Claude, what do you think?")
    end

    job = enqueued_jobs.find { |j| j["job_class"] == "AllAgentsResponseJob" }
    mentioned_ids = job["arguments"].last
    assert_includes mentioned_ids, agent1.id
    assert_includes mentioned_ids, agent2.id
    assert_not_includes mentioned_ids, agent3.id
  end

  test "trigger_mentioned_agents! only matches agents in this chat" do
    agent_in_chat = @account.agents.create!(name: "Grok", system_prompt: "Test")
    @account.agents.create!(name: "Claude", system_prompt: "Test")
    chat = @account.chats.new(model_id: "openrouter/auto", manual_responses: true)
    chat.agent_ids = [ agent_in_chat.id ]
    chat.save!

    assert_enqueued_with(job: AllAgentsResponseJob, args: [ chat, [ agent_in_chat.id ] ]) do
      chat.trigger_mentioned_agents!("Hey @Grok and @Claude")
    end
  end

  test "trigger_mentioned_agents! handles names with special regex characters" do
    agent = @account.agents.create!(name: "C++Bot", system_prompt: "Test")
    chat = @account.chats.new(model_id: "openrouter/auto", manual_responses: true)
    chat.agent_ids = [ agent.id ]
    chat.save!

    assert_enqueued_with(job: AllAgentsResponseJob, args: [ chat, [ agent.id ] ]) do
      chat.trigger_mentioned_agents!("Hey @C++Bot, help me")
    end
  end

  test "trigger_mentioned_agents! works with multi-word agent names" do
    agent = @account.agents.create!(name: "GPT Test Agent", system_prompt: "Test")
    chat = @account.chats.new(model_id: "openrouter/auto", manual_responses: true)
    chat.agent_ids = [ agent.id ]
    chat.save!

    assert_enqueued_with(job: AllAgentsResponseJob, args: [ chat, [ agent.id ] ]) do
      chat.trigger_mentioned_agents!("Hey @GPT Test Agent, can you please respond?")
    end
  end

  # Audio input support tests

  test "supports_audio_input? returns true for Gemini models" do
    assert Chat.supports_audio_input?("google/gemini-3-pro-preview")
    assert Chat.supports_audio_input?("google/gemini-3-flash-preview")
    assert Chat.supports_audio_input?("google/gemini-2.5-pro")
    assert Chat.supports_audio_input?("google/gemini-2.5-flash")
  end

  test "supports_audio_input? returns false for non-Gemini models" do
    assert_not Chat.supports_audio_input?("openai/gpt-4o")
    assert_not Chat.supports_audio_input?("anthropic/claude-opus-4.6")
    assert_not Chat.supports_audio_input?("x-ai/grok-4")
    assert_not Chat.supports_audio_input?("unknown/model")
  end

  test "audio annotation only added when audio_tools_enabled" do
    agent = @account.agents.create!(name: "TestBot", system_prompt: "Test", model_id: "google/gemini-2.5-pro")
    chat = @account.chats.new(model_id: "google/gemini-2.5-pro", manual_responses: true)
    chat.agent_ids = [ agent.id ]
    chat.save!

    message = chat.messages.create!(
      role: "user",
      user: @user,
      content: "Hello there",
      audio_source: true
    )
    message.audio_recording.attach(
      io: StringIO.new("fake audio"),
      filename: "recording.webm",
      content_type: "audio/webm"
    )

    context = chat.build_context_for_agent(agent)

    # Find the user message in context
    user_msg = context.find { |m| m[:role] == "user" && m[:content].to_s.include?("Hello there") }
    assert user_msg, "Should find the user message in context"
    assert_includes user_msg[:content].to_s, "[voice message, audio_id:"
  end

  test "audio annotation omitted when audio_tools_enabled is false" do
    agent = @account.agents.create!(name: "TestBot", system_prompt: "Test", model_id: "openai/gpt-4o")
    chat = @account.chats.new(model_id: "openai/gpt-4o", manual_responses: true)
    chat.agent_ids = [ agent.id ]
    chat.save!

    message = chat.messages.create!(
      role: "user",
      user: @user,
      content: "Hello there",
      audio_source: true
    )
    message.audio_recording.attach(
      io: StringIO.new("fake audio"),
      filename: "recording.webm",
      content_type: "audio/webm"
    )

    context = chat.build_context_for_agent(agent)

    # Find the user message in context
    user_msg = context.find { |m| m[:role] == "user" && m[:content].to_s.include?("Hello there") }
    assert user_msg, "Should find the user message in context"
    assert_not_includes user_msg[:content].to_s, "[voice message, audio_id:"
  end

  test "Anthropic context caches the stable system prefix before the context envelope" do
    agent = @account.agents.create!(
      name: "Cached Claude",
      system_prompt: "Stable identity",
      model_id: "anthropic/claude-opus-4.6"
    )
    chat = @account.chats.new(title: "Cache test", manual_responses: true, model_id: agent.model_id)
    chat.agent_ids = [ agent.id ]
    chat.save!

    context = chat.build_context_for_agent(agent, provider: :anthropic)

    assert_instance_of RubyLLM::Content::Raw, context.first[:content]
    assert_includes context.first[:content].value.first[:text], "Stable identity"
    assert_includes context.first[:content].value.first[:text], "Each activation includes a `<helixkit_context>` block"
    assert_not_includes context.first[:content].value.first[:text], "Current time:"
    assert_equal({ type: "ephemeral", ttl: "1h" }, context.first[:content].value.first[:cache_control])
    assert_includes context.second[:content], "Current time:"
    assert_includes context.second[:content], "Cache test"
  end

  # Cross-conversation context tests

  test "format_cross_conversation_context returns nil when no other conversations" do
    agent = @account.agents.create!(name: "Solo Agent", system_prompt: "Test", model_id: "openrouter/auto")
    chat = @account.chats.new(title: "Only Chat", manual_responses: true, model_id: "openrouter/auto")
    chat.agent_ids = [ agent.id ]
    chat.save!

    context = chat.build_context_for_agent(agent)
    system_content = context.first[:content]
    assert_not_includes system_content, "Your Other Active Conversations"
  end

  test "format_cross_conversation_context formats summaries with obfuscated IDs" do
    agent = @account.agents.create!(name: "Cross Conv Agent", system_prompt: "Test", model_id: "openrouter/auto")

    chat1 = @account.chats.new(title: "Current Chat", manual_responses: true, model_id: "openrouter/auto")
    chat1.agent_ids = [ agent.id ]
    chat1.save!

    chat2 = @account.chats.new(title: "Other Chat", manual_responses: true, model_id: "openrouter/auto")
    chat2.agent_ids = [ agent.id ]
    chat2.save!

    ca2 = ChatAgent.find_by(chat: chat2, agent: agent)
    ca2.update_columns(agent_summary: "Discussing API design patterns", agent_summary_generated_at: 1.minute.ago)

    context = chat1.build_context_for_agent(agent)
    envelope_content = context.last[:content]

    assert_includes envelope_content, "Your Other Active Conversations"
    assert_includes envelope_content, "Other Chat"
    assert_includes envelope_content, "Discussing API design patterns"
    assert_includes envelope_content, chat2.obfuscated_id
  end

  test "format_borrowed_context returns nil when no borrowed context" do
    agent = @account.agents.create!(name: "No Borrow Agent", system_prompt: "Test", model_id: "openrouter/auto")
    chat = @account.chats.new(title: "Test", manual_responses: true, model_id: "openrouter/auto")
    chat.agent_ids = [ agent.id ]
    chat.save!

    context = chat.build_context_for_agent(agent)
    system_content = context.first[:content]
    assert_not_includes system_content, "Borrowed Context"
  end

  test "format_borrowed_context formats messages without consuming them" do
    agent = @account.agents.create!(name: "Borrow Agent", system_prompt: "Test", model_id: "openrouter/auto")
    chat = @account.chats.new(title: "Current", manual_responses: true, model_id: "openrouter/auto")
    chat.agent_ids = [ agent.id ]
    chat.save!

    ca = ChatAgent.find_by(chat: chat, agent: agent)
    ca.update!(borrowed_context_json: {
      "source_conversation_id" => "abcdef",
      "messages" => [
        { "author" => "Alice", "content" => "Can you review the PR?" },
        { "author" => "Bot", "content" => "I will review it now." }
      ]
    })

    context = chat.build_context_for_agent(agent)
    envelope_content = context.last[:content]

    assert_includes envelope_content, "Borrowed Context from Conversation abcdef"
    assert_includes envelope_content, "[Alice]: Can you review the PR?"
    assert_includes envelope_content, "[Bot]: I will review it now."
    assert_includes envelope_content, "will not appear in future activations"

    # Verify context is NOT consumed (still present)
    assert ca.reload.borrowed_context_json.present?
  end

end
