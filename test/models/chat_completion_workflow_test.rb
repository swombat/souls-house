require "test_helper"

class ChatCompletionWorkflowTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
    @user = @agent.account.memberships.confirmed.first.user
    @chat = @agent.account.chats.create!(title: "Completion", model_id: "openrouter/auto",
      agents: [ @agent ], manual_responses: true)
    @fields = { "changes_summary" => "Built the feature", "result" => "PR 123",
      "checks" => "Tests passed", "remaining" => "Nothing" }
  end

  test "handoff is saved before review and is not its own unanswered request" do
    completion = submit
    assert_equal "ready_for_review", @chat.reload.work_status
    assert_equal "system", completion.message.role
    assert_includes completion.message.content, "Built the feature"
    assert_not completion.message.reply_attention_pending?
    assert_empty ReplyExpectation.where(message: completion.message)
    assert_nil completion.accepted_at
    assert_not @chat.archived?
    assert_raises(ActiveRecord::RecordInvalid) { completion.update!(changes_summary: "Rewritten") }
  end

  test "submission retry is idempotent but key reuse with changed content conflicts" do
    first = submit
    assert_equal first, submit
    assert_equal 1, @chat.work_completions.count
    assert_raises(Chat::WorkStatus::Conflict) { submit(fields: @fields.merge("checks" => "Other checks")) }
    assert_raises(Chat::WorkStatus::Invalid) { submit(revision: 0.0) }
  end

  test "human acceptance archives only after saved handoff" do
    completion = submit
    accept(completion)
    assert_equal "completed", @chat.reload.work_status
    assert @chat.archived?
    assert completion.reload.accepted_at
    assert completion.closed_at
    assert_equal @user, completion.accepted_by
    @chat.with_completion_authority!(user: @user) do
      assert_raises(Chat::WorkStatus::Invalid) do
        @chat.accept_completion!(completion: completion, user: @user, expected_revision: 1.0, auto_close: true)
      end
      assert_raises(Chat::WorkStatus::Invalid) do
        @chat.close_completion!(completion: completion, expected_revision: 2.0)
      end
    end
    @chat.unarchive!
    assert_equal "completed", @chat.work_status
    assert_not completion.as_work_json[:current]
  end

  test "pending expectations block automatic human closure without losing accepted work" do
    completion = submit
    message = @chat.messages.create!(role: "assistant", agent: @agent, content: "Still need your answer")
    expectation = ReplyExpectation.record!(message: message, user: @user, score: 1.0, classifier_version: "test")
    accept(completion)
    assert_not @chat.reload.archived?
    assert completion.reload.accepted_at
    assert_equal "conversation_has_pending_work", completion.closure_blocked["code"]
    assert_equal "open", expectation.reload.state
  end

  test "new reported work invalidates old handoff acceptance" do
    completion = submit
    @chat.with_work_status_authority!(agent: @agent) do
      @chat.change_work_status!(state: "working", reason: nil, expected_revision: 1)
    end
    assert_raises(Chat::WorkStatus::Conflict) { accept(completion) }
    assert_nil completion.reload.accepted_at
  end

  test "no review authorisation is revision bound and consumed once" do
    grant
    completion = submit
    assert completion.accepted_at
    assert @chat.reload.archived?
    assert @chat.work_completion_permissions.first.consumed_at
  end

  test "a changed revision cannot reuse permission" do
    grant
    @chat.with_work_status_authority!(agent: @agent) do
      @chat.change_work_status!(state: "working", reason: nil, expected_revision: 0)
    end
    completion = submit(revision: 1)
    assert_nil completion.accepted_at
    assert_not @chat.reload.archived?
  end

  test "invalid handoff fields roll back without a receipt or status change" do
    assert_no_difference [ "Message.count", "WorkCompletion.count" ] do
      assert_raises(ActiveRecord::RecordInvalid) { submit(fields: @fields.merge("checks" => "")) }
    end
    assert_equal 0, @chat.reload.work_status_revision
  end

  private

  def submit(fields: @fields, revision: 0)
    @chat.with_completion_authority!(agent: @agent) do
      @chat.submit_completion!(agent: @agent, expected_revision: revision, request_key: "request-one", fields: fields)
    end
  end

  def accept(completion)
    @chat.with_completion_authority!(user: @user) do
      @chat.accept_completion!(completion: completion, user: @user,
        expected_revision: completion.review_revision, auto_close: true)
    end
  end

  def grant
    @chat.with_completion_authority!(user: @user) do
      @chat.grant_completion_permission!(user: @user, expected_revision: 0, auto_close: true)
    end
  end

end
