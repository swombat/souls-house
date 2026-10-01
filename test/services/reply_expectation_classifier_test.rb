require "test_helper"

class ReplyExpectationClassifierTest < ActiveSupport::TestCase

  test "typed questions distinguish addressee from mention and do not classify the author" do
    user = users(:user_1)
    other = users(:existing_user)
    chat = accounts(:personal_account).chats.create!(title: "Classify")
    message = chat.messages.create!(role: "user", user: user, content: "Maybe ask Daniel whether he wants it moved")
    UtilityInference.stub :decide, ->(state:, questions:) {
      assert_equal [ user, other ].map { |person| { id: person.id, name: person.full_name } }, state[:people]
      refute_includes state.to_json, user.email_address
      refute_includes state.to_json, other.email_address
      assert_equal 2, questions.size
      question = questions.fetch("m#{message.id}_u#{other.id}")
      assert_equal "noul", question[:type]
      assert_includes question[:instructions], "subject of somebody else's question"
      assert_includes question[:instructions], "not automatically the human"
      assert_equal message.content, state[:messages].first[:content]
      questions.transform_values { 0.49 }
    } do
      assert_equal({ message.id => {} }, ReplyExpectationClassifier.new(messages: [ message ], users: [ user, other ]).call)
    end
  end

  test "accepts the configured threshold boundary" do
    user = users(:user_1)
    chat = accounts(:personal_account).chats.create!(title: "Threshold")
    message = chat.messages.create!(role: "assistant", content: "Could you confirm?")
    UtilityInference.stub :decide, ->(state:, questions:) { questions.transform_values { 0.50 } } do
      assert_equal({ message.id => { user.id => 0.50 } }, ReplyExpectationClassifier.new(messages: [ message ], users: [ user ]).call)
    end
  end

  test "both response and recipient decisions must pass" do
    user = users(:user_1)
    chat = accounts(:personal_account).chats.create!(title: "Two decisions")
    message = chat.messages.create!(role: "assistant", content: "A progress update")
    [ [ 0.49, 0.95 ], [ 0.95, 0.49 ] ].each do |response_score, recipient_score|
      UtilityInference.stub :decide, ->(state:, questions:) {
        { "m#{message.id}_reply" => response_score, "m#{message.id}_u#{user.id}" => recipient_score }
      } do
        assert_equal({ message.id => {} }, ReplyExpectationClassifier.new(messages: [ message ], users: [ user ]).call)
      end
    end
  end

  test "only the author as candidate does not invoke inference" do
    user = users(:user_1)
    chat = accounts(:personal_account).chats.create!(title: "No self assignment")
    message = chat.messages.create!(role: "user", user: user, content: "Can I do this?")
    UtilityInference.stub :decide, ->(**) { flunk "No eligible recipient" } do
      assert_equal({ message.id => {} }, ReplyExpectationClassifier.new(messages: [ message ], users: [ user ]).call)
    end
  end

  test "a batch uses each message's own response decision and stores the lower score" do
    user = users(:user_1)
    chat = accounts(:personal_account).chats.create!(title: "Batch")
    ask = chat.messages.create!(role: "assistant", content: "Want it?")
    update = chat.messages.create!(role: "assistant", content: "I am checking")
    UtilityInference.stub :decide, ->(state:, questions:) {
      assert_equal 4, questions.size
      { "m#{ask.id}_reply" => 0.9, "m#{ask.id}_u#{user.id}" => 0.6,
        "m#{update.id}_reply" => 0.1, "m#{update.id}_u#{user.id}" => 0.95 }
    } do
      assert_equal({ ask.id => { user.id => 0.6 }, update.id => {} },
        ReplyExpectationClassifier.new(messages: [ ask, update ], users: [ user ]).call)
    end
  end

end
