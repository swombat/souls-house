require "test_helper"

class InferredReplyRecipientsTest < ActiveSupport::TestCase

  setup do
    @daniel = users(:user_1)
    @daniel.profile.update!(first_name: "Daniel", last_name: "Tenner")
    @pepe = users(:existing_user)
    @pepe.profile.update!(first_name: "Pepe", last_name: "Mexzungu")
    @users = [ @daniel, @pepe ]
    @chat = accounts(:personal_account).chats.create!(title: "Recipients")
  end

  test "someone who wrote earlier keeps the flag; a silent member does not" do
    @chat.messages.create!(role: "user", user: @pepe, content: "What do you think?")
    ask = @chat.messages.create!(role: "assistant", content: "I think you should wait.")
    assert_equal [ @pepe.id ], eligible(ask)
  end

  test "writing only after the message does not count" do
    ask = @chat.messages.create!(role: "assistant", content: "Should we wait?")
    @chat.messages.create!(role: "user", user: @pepe, content: "Yes")
    assert_empty eligible(ask)
  end

  test "a first or unique last name as a whole word, in any case, names someone" do
    assert_equal [ @daniel.id ], eligible(ask("we need to ask daniel's view"))
    assert_equal [ @pepe.id ], eligible(ask("Señor MEXZUNGU, ¿qué opinas?"))
  end

  test "a name inside another word does not count" do
    assert_empty eligible(ask("Danielle and Pepeto, any thoughts?"))
  end

  test "a last name shared with another confirmed member names neither" do
    @pepe.profile.update!(first_name: "Lume", last_name: "Tenner")
    assert_empty eligible(ask("Signed, a Tenner. Any thoughts?"))
    assert_equal [ @pepe.id ], eligible(ask("Lume Tenner, any thoughts?"))
  end

  private

  def ask(content)
    @chat.messages.create!(role: "assistant", content: content)
  end

  def eligible(message)
    InferredReplyRecipients.call(message: message, user_ids: @users.map(&:id), users: @users)
  end

end
