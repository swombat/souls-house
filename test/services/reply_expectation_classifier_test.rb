require "test_helper"

class ReplyExpectationClassifierTest < ActiveSupport::TestCase

  setup do
    @user = users(:user_1)
    @other = users(:existing_user)
    @chat = accounts(:personal_account).chats.create!(title: "Classifier")
    @resident = agents(:research_assistant)
    @chat.agents << @resident
    @message = @chat.messages.create!(role: "assistant", agent: @resident, content: "Want it?")
  end

  test "both providers see only ID name and kind metadata and Luna can choose a resident" do
    UtilityInference.stub :decide, ->(state:, questions:) {
      assert_equal 1, questions.size
      assert_equal "noul", questions.values.first[:type]
      assert_equal %w[human human resident], state[:people].pluck(:kind)
      refute_includes state.to_json, @user.email_address
      refute_includes state.to_json, @other.email_address
      questions.transform_values { 0.9 }
    } do
      UtilityInference.stub :structured, ->(state:, model:, effort:, **options) {
        assert_equal "openai/gpt-6-luna", model
        assert_equal "low", effort
        assert_equal [ :id, :name, :kind ], state[:people].first.keys
        refute_includes state.to_json, @user.email_address
        refute_includes state.to_json, @other.email_address
        assert_includes state[:people].pluck(:id), "agent:#{@resident.id}"
        response([ "agent:#{@resident.id}" ])
      } do
        assert_equal({ @message.id => {} }, classify)
      end
    end
  end

  test "below the response threshold does not pay for Luna" do
    UtilityInference.stub :decide, ->(state:, questions:) { questions.transform_values { 0.49 } } do
      UtilityInference.stub :structured, ->(**) { flunk "No recipient call" } do
        assert_equal({ @message.id => {} }, classify)
      end
    end
  end

  test "threshold boundary accepts a human and stores the Jev gate score" do
    UtilityInference.stub :decide, ->(state:, questions:) { questions.transform_values { 0.5 } } do
      UtilityInference.stub :structured, response([ "user:#{@user.id}" ]) do
        assert_equal({ @message.id => { @user.id => 0.5 } }, classify)
      end
    end
    assert_includes ReplyExpectationClassifier::VERSION, "typesafe/jev-1.13"
    assert_includes ReplyExpectationClassifier::VERSION, "openai/gpt-6-luna/low"
  end

  test "uncertain is no verdict and certain empty is a negative verdict" do
    UtilityInference.stub :decide, ->(state:, questions:) { questions.transform_values { 0.9 } } do
      UtilityInference.stub :structured, response([ "user:#{@user.id}" ], uncertain: true) do
        assert_equal({}, classify)
      end
      UtilityInference.stub :structured, response([]) do
        assert_equal({ @message.id => {} }, classify)
      end
    end
  end

  test "a human author can never assign a reply to self" do
    @message.update!(role: "user", agent: nil, user: @user)
    UtilityInference.stub :decide, ->(state:, questions:) { questions.transform_values { 0.9 } } do
      UtilityInference.stub :structured, response([ "user:#{@user.id}" ]) do
        assert_equal({ @message.id => {} }, classify)
      end
    end
    UtilityInference.stub :decide, ->(**) { flunk "Only author eligible" } do
      assert_equal({ @message.id => {} }, ReplyExpectationClassifier.new(messages: [ @message ], users: [ @user ]).call)
    end
  end

  test "invalid missing duplicate or alien IDs are errors not negative decisions" do
    bad = [ response([ "user:999999999" ]), response([ "agent:#{@resident.id}", "agent:#{@resident.id}" ]),
      { "decisions" => [] }, { "decisions" => response([])["decisions"] * 2 },
      { "decisions" => [ { "message_id" => "wrong", "recipient_ids" => [], "uncertain" => false } ] },
      response([]).deep_merge("extra" => true) ]
    UtilityInference.stub :decide, ->(state:, questions:) { questions.transform_values { 0.9 } } do
      bad.each do |value|
        UtilityInference.stub :structured, value do
          assert_raises(UtilityInference::InvalidResponse) { classify }
        end
      end
    end
  end

  test "triggering human is context and does not override the returned resident" do
    dispatch = Struct.new(:chat_id, :user_id).new(@chat.id, @user.id)
    interaction = Struct.new(:chat_id, :message_dispatch).new(@chat.id, dispatch)
    @message.stub :runtime_interaction, interaction do
      UtilityInference.stub :decide, ->(state:, questions:) { questions.transform_values { 0.9 } } do
        UtilityInference.stub :structured, ->(state:, **options) {
          assert_equal "user:#{@user.id}", state[:messages].first[:triggering_user_id]
          response([ "agent:#{@resident.id}" ])
        } do
          assert_equal({ @message.id => {} }, classify)
        end
      end
    end
  end

  test "one Luna call covers only positive messages and keeps abstention separate" do
    second = @chat.messages.create!(role: "assistant", agent: @resident, content: "Fable, can you check the cert?")
    third = @chat.messages.create!(role: "assistant", agent: @resident, content: "Thanks")
    calls = 0
    UtilityInference.stub :decide, ->(state:, questions:) {
      questions.keys.each_with_index.to_h { |key, i| [ key, i == 2 ? 0.1 : 0.9 ] }
    } do
      UtilityInference.stub :structured, ->(state:, **options) {
        calls += 1
        assert_equal [ @message.id, second.id ], state[:target_message_ids]
        { "decisions" => [
          { "message_id" => @message.id, "recipient_ids" => [ "user:#{@user.id}" ], "uncertain" => false },
          { "message_id" => second.id, "recipient_ids" => [ "agent:#{@resident.id}" ], "uncertain" => true }
        ] }
      } do
        result = ReplyExpectationClassifier.new(messages: [ @message, second, third ], users: [ @user ]).call
        assert_equal({ @message.id => { @user.id => 0.9 }, third.id => {} }, result)
        assert_equal 1, calls
      end
    end
  end

  private

  def classify
    ReplyExpectationClassifier.new(messages: [ @message ], users: [ @user, @other ]).call
  end

  def response(ids, uncertain: false)
    { "decisions" => [ { "message_id" => @message.id, "recipient_ids" => ids, "uncertain" => uncertain } ] }
  end

end
