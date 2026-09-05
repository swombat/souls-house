require "test_helper"

class InlineRuntimeRetirementTest < ActiveJob::TestCase

  test "serialized legacy jobs drain without inference or writes" do
    agent = agents(:research_assistant)
    chat = agent.account.chats.create!(title: "Legacy queue", manual_responses: true, agents: [ agent ])
    jobs = [
      [ AiResponseJob, chat ],
      [ ManualAgentResponseJob, chat, agent ],
      [ AgentInitiationDecisionJob, agent ],
      [ ConversationInitiationJob ],
      [ AgentMigrationSweeperJob ],
      [ MemoryReflectionJob ],
      [ MemoryRefinementJob, agent ],
      [ GenerateAgentSummaryJob, chat, agent ]
    ]
    agent.update_columns(runtime: "deprecated")
    snapshot = agent.reload.attributes

    UtilityInference.stub(:title, ->(*) { flunk "retired jobs must not infer" }) do
      assert_no_enqueued_jobs do
        assert_no_difference [ "Message.count", "AgentMemory.count", "ApiKey.count" ] do
          jobs.each { |klass, *args| klass.perform_now(*args) }
        end
      end
    end

    assert_equal snapshot, agent.reload.attributes
    assert_not defined?(RubyLLM)
    assert_not Chat.new.respond_to?(:ask)
    assert_not Message.new.respond_to?(:to_llm)
    assert_not Agent.new.respond_to?(:tools)
  end

end
