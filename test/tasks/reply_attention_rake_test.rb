require "test_helper"
require "rake"

class ReplyAttentionRakeTest < ActiveSupport::TestCase

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("reply_attention:dismiss_ineligible_inferred")
    @task = Rake::Task["reply_attention:dismiss_ineligible_inferred"]
    @task.reenable
    @user = users(:user_1)
    @chat = accounts(:personal_account).chats.create!(title: "Cleanup")
    @named = flag("Test, could you look?")
    @silent = flag("Could you look?")
    @tagged = flag("Could you look too?", version: ReplyExpectation::DIRECT_MENTION_VERSION)
  end

  teardown { ENV.delete("APPLY") }

  test "dry run counts and changes nothing" do
    out, = capture_io { @task.invoke }
    assert_match "Would dismiss 1 of 2 open inferred flags", out
    assert [ @named, @silent, @tagged ].all? { |e| e.reload.state_open? }
  end

  test "APPLY dismisses only the failing inferred flag, never a tag" do
    ENV["APPLY"] = "1"
    capture_io { @task.invoke }
    assert @named.reload.state_open?
    assert @silent.reload.state_dismissed?
    assert @tagged.reload.state_open?
  end

  private

  def flag(content, version: ReplyExpectationClassifier::VERSION)
    message = @chat.messages.create!(role: "assistant", content: content)
    @chat.with_lock { ReplyExpectation.record!(message: message, user: @user, score: 0.9, classifier_version: version) }
  end

end
