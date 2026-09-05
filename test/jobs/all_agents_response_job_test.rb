require "test_helper"

class AllAgentsResponseJobTest < ActiveJob::TestCase

  setup do
    @first = agents(:research_assistant)
    @second = agents(:code_reviewer)
    @chat = @first.account.chats.create!(title: "All harnesses", manual_responses: true, agents: [ @first, @second ])
  end

  test "dispatches first resident and queues the remaining chain" do
    calls = []
    ManualAgentResponseJob.stub(:perform_now, ->(*args) { calls << args }) do
      assert_enqueued_with(job: AllAgentsResponseJob, args: [ @chat, [ @second.id ] ]) do
        AllAgentsResponseJob.perform_now(@chat, [ @first.id, @second.id ])
      end
    end
    assert_equal [ [ @chat, @first ] ], calls
  end

  test "removed participants do not stall the remaining chain" do
    @chat.chat_agents.find_by!(agent: @first).destroy!
    ManualAgentResponseJob.stub(:perform_now, ->(*) { flunk "removed participant" }) do
      assert_enqueued_with(job: AllAgentsResponseJob, args: [ @chat, [ @second.id ] ]) do
        AllAgentsResponseJob.perform_now(@chat, [ @first.id, @second.id ])
      end
    end
  end

  test "empty and archived chains do not dispatch" do
    ManualAgentResponseJob.stub(:perform_now, ->(*) { flunk "must not dispatch" }) do
      assert_no_enqueued_jobs do
        AllAgentsResponseJob.perform_now(@chat, [])
        @chat.archive!
        AllAgentsResponseJob.perform_now(@chat, [ @first.id ])
      end
    end
  end

end
