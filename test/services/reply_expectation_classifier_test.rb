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
      assert_equal 1, questions.size
      question = questions.values.first
      assert_equal "noul", question[:type]
      assert_includes question[:criteria]["false"], "tells somebody else to ask them"
      assert_includes question[:criteria]["false"], "need not reply"
      assert_equal message.content, state[:messages].first[:content]
      questions.transform_values { 0.84 }
    } do
      assert_equal({ message.id => {} }, ReplyExpectationClassifier.new(messages: [ message ], users: [ user, other ]).call)
    end
  end

end
