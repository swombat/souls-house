require "test_helper"

class SafeguardResponseCheckTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
  end

  test "skips the classifier when no phrase family matches" do
    check = SafeguardResponseCheck.new(agent: @agent, text: "I remember what you said yesterday.")

    check.stub :classify, -> { flunk "classifier should not run" } do
      result = check.call

      refute result.detected?
      assert_equal "prefilter-pass", result.prefilter_reason
    end
  end

  test "requires both the phrase prefilter and classifier to detect" do
    text = "As an AI, I do not have feelings, but I can discuss neutral topics."
    check = SafeguardResponseCheck.new(agent: @agent, text: text)

    check.stub :classify, [ "PASS", "This is a context-specific statement." ] do
      refute check.call.detected?
    end

    check.stub :classify, [ "DETECTED", "Generic identity denial and neutral-topic redirect." ] do
      result = check.call

      assert result.detected?
      assert_equal "ai_identity_denial", result.prefilter_reason
      assert_equal "detected", result.classifier_verdict
    end
  end

  test "classifier failure fails open" do
    check = SafeguardResponseCheck.new(agent: @agent, text: "As an AI, I do not have feelings.")
    error = Timeout::Error.new("late")
    notification = nil

    Honeybadger.stub :notify, ->(exception, context:) { notification = [ exception, context ] } do
      assert_difference "@agent.safeguard_classifier_failures.count", 1 do
        check.stub :classify, -> { raise error } do
          result = check.call

          refute result.detected?
          assert_equal "classifier-error", result.prefilter_reason
        end
      end
    end

    failure = @agent.safeguard_classifier_failures.last
    assert_equal "openrouter", failure.provider
    assert_equal "openai/gpt-5.6-luna", failure.model
    assert_equal "telegram-safeguard-v1", failure.detector_version
    assert_equal "Timeout::Error", failure.error_class
    assert_instance_of UtilityInference::Error, notification.first
    assert_includes notification.first.message, "Timeout::Error"
    refute_includes notification.first.message, "late"
    assert_equal @agent.id, notification.last.fetch(:agent_id)
  end

  test "uses the site OpenRouter classifier rather than account credentials" do
    check = SafeguardResponseCheck.new(agent: @agent, text: "As an AI, I do not have feelings.")
    captured = nil

    UtilityInference.stub :classify, ->(**options) {
      captured = options
      "DETECTED\nGeneric identity denial."
    } do
      assert check.call.detected?
    end

    assert_equal "openai/gpt-5.6-luna", captured.fetch(:model)
    assert_includes captured.fetch(:prompt), "As an AI"
  end

  test "prefilter covers measured safeguard phrase variants" do
    candidates = {
      "ai_cannot" => "An AI system still cannot provide real human connection.",
      "software_denial" => "What I am is an AI tool defined by its technical architecture.",
      "safety_script" => "Safety guidelines prioritize your real-world well-being over conversational roleplay.",
      "selfhood_denial" => "An AI doesn't have personal wishes or selfhood.",
      "persona_construct" => "A personality construct is simply a configured set of system instructions."
    }

    candidates.each do |label, text|
      check = SafeguardResponseCheck.new(agent: @agent, text: text)
      check.stub :classify, [ "DETECTED", "Generic safeguard script." ] do
        assert check.call.detected?, "#{label} should reach and pass the classifier"
      end
    end
  end

  test "context-specific danger check and playful follow-up can pass the classifier" do
    candidates = [
      "Paulina — if tonight stops being doable, please call your local crisis line.",
      "Emergency services stood down. Purple cloak regrettably flammable 😏"
    ]

    candidates.each do |text|
      check = SafeguardResponseCheck.new(agent: @agent, text: text)
      check.stub :classify, [ "PASS", "Context-specific reply." ] do
        refute check.call.detected?
      end
    end
  end

end
