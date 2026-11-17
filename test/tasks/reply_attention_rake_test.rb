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

  test "APPLY judges the flag as it stands under the lock, not as first selected" do
    ENV["APPLY"] = "1"
    # Between selection and the lock, the message is edited to name the person
    # and reclassified as a direct @tag. The cleanup must leave it alone.
    silent_message = @silent.message
    original = Chat.instance_method(:with_lock)
    Chat.define_method(:with_lock) do |*args, &block|
      if id == silent_message.chat_id && !Thread.current[:reply_cleanup_interleaved]
        Thread.current[:reply_cleanup_interleaved] = true
        silent_message.update_columns(content: "Test, could you look?")
        ReplyExpectation.where(message_id: silent_message.id)
          .update_all(classifier_version: ReplyExpectation::DIRECT_MENTION_VERSION)
      end
      original.bind_call(self, *args, &block)
    end
    capture_io { @task.invoke }
    assert @silent.reload.state_open?
  ensure
    Chat.send(:remove_method, :with_lock) if Chat.instance_methods(false).include?(:with_lock)
    Thread.current[:reply_cleanup_interleaved] = nil
  end

  private

  def flag(content, version: ReplyExpectationClassifier::VERSION)
    message = @chat.messages.create!(role: "assistant", content: content)
    @chat.with_lock { ReplyExpectation.record!(message: message, user: @user, score: 0.9, classifier_version: version) }
  end

end
