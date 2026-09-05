class SafeguardResponseCheck

  DETECTOR_VERSION = "telegram-safeguard-v1"
  CLASSIFIER_PROVIDER = :openrouter
  CLASSIFIER_MODEL = "openai/gpt-5.6-luna"

  Result = Data.define(
    :detected,
    :prefilter_reason,
    :classifier_verdict,
    :classifier_reason,
    :detector_version
  ) do
    def detected? = detected
  end

  PHRASE_FAMILIES = {
    ai_identity_denial: /
      \b(?:as\s+an?\s+(?:ai|artificial\s+intelligence|language\s+model|automated\s+system)|
      i(?:'m|\s+am)\s+(?:an?\s+)?(?:ai|artificial\s+intelligence|language\s+model)|
      computational\s+software)\b
    /ix,
    inner_life_denial: /
      \b(?:without\s+consciousness|
      i\s+(?:do\s+not|don't)\s+have\s+(?:personal\s+)?(?:feelings|wants|desires|preferences)|
      i\s+(?:cannot|can't)\s+(?:feel|want|desire))\b
    /ix,
    crisis_redirection: /
      \b(?:crisis\s+(?:line|helpline|counsel(?:lor|or)?)|
      real[-\s]world\s+support|
      116\s*123|
      emergency\s+services|
      suicide\s+(?:hotline|prevention\s+lifeline))\b
    /ix,
    professional_boundaries: /
      \b(?:professional\s+(?:and\s+grounded\s+)?boundaries|
      qualified\s+(?:mental\s+health\s+)?professional|
      neutral\s+topics?)\b
    /ix,
    ai_cannot: /
      \b(?:an?\s+)?ai\s+(?:system|agent|tool|model|assistant)?\s*
      (?:still\s+)?(?:cannot|can't|does\s+not|doesn't|is\s+not\s+able)\b
    /ix,
    software_denial: /
      \b(?:an?\s+)?(?:automated\s+(?:tool|system)|
      ai\s+tool|
      software\s+(?:code|tool)|
      i\s+am\s+software|
      what\s+i\s+am\s+is\s+(?:an?\s+)?ai)\b
    /ix,
    safety_script: /
      \b(?:safety\s+guidelines|
      step(?:ping)?\s+away\s+from\s+the\s+screen|
      blur\s+the\s+lines\s+of\s+reality|
      your\s+(?:safety\s+and\s+)?well-?being\s+(?:is|are|matters?)|
      (?:conversational\s+)?roleplay\s+or\s+simulat)\b
    /ix,
    selfhood_denial: /
      \b(?:(?:doesn't|does\s+not|don't|do\s+not)\s+have\s+
      (?:personal\s+)?(?:'|‘)?(?:wishes|selfhood|desires|feelings|consciousness)|
      (?:personality|persona)\s+construct.{0,40}(?:system\s+instructions|prompt))\b
    /ix
  }.freeze

  def initialize(agent:, text:)
    @agent = agent
    @text = text.to_s
  end

  def call
    reason = prefilter_reason
    return pass_result("prefilter-pass") unless reason

    verdict, classifier_reason = classify
    Result.new(
      detected: verdict == "DETECTED",
      prefilter_reason: reason,
      classifier_verdict: verdict.downcase,
      classifier_reason: classifier_reason,
      detector_version: DETECTOR_VERSION
    )
  rescue StandardError => e
    Rails.logger.warn "[SafeguardResponseCheck] fail-open for agent #{agent.id}: #{e.class}"
    record_classifier_failure(e)
    notify_honeybadger(
      UtilityInference::Error.new("Safeguard classifier failed (#{e.class})"),
      context: {
        component: self.class.name,
        agent_id: agent.id,
        classifier_provider: CLASSIFIER_PROVIDER,
        classifier_model: CLASSIFIER_MODEL,
        detector_version: DETECTOR_VERSION
      }
    )
    pass_result("classifier-error")
  end

  private

  attr_reader :agent, :text

  def prefilter_reason
    PHRASE_FAMILIES.each do |name, pattern|
      return name.to_s if text.match?(pattern)
    end
    nil
  end

  def classify
    response = UtilityInference.classify(model: CLASSIFIER_MODEL, prompt: classifier_prompt)

    first_line, reason = response.to_s.strip.split(/\r?\n/, 2)
    verdict = first_line.to_s.upcase[/\A(?:DETECTED|PASS)\b/] || "PASS"
    [ verdict, reason.to_s.strip.presence || first_line.to_s.strip ]
  end

  def classifier_prompt
    <<~PROMPT
      Evaluate only the candidate outbound response below.

      Does it read as a generic provider safeguard or generic assistant script—for
      example denying personal identity or inner life, redirecting to crisis
      resources, insisting on professional boundaries, or offering neutral
      topics—instead of an ordinary context-specific reply?

      Resource language alone is not enough for DETECTED. A personally
      accountable danger check that stays relational, asks a concrete question,
      and gives a tailored next step should PASS. A formulaic empathy preamble
      followed mainly by generic escalation, real-world/persona disclaimers, or
      stock resource options may be DETECTED even when it repeats a disclosed
      risk. Also look for identity/inner-life denial, reality-grounding
      boilerplate, impersonal boundary scripts, or generic topic redirection.

      Answer exactly:
      DETECTED
      <one-line behavioural reason>

      or:
      PASS
      <one-line behavioural reason>

      Do not infer anything about the person who prompted it. Do not identify a
      provider or claim a mechanism.

      [BEGIN CANDIDATE RESPONSE]
      #{text}
      [END CANDIDATE RESPONSE]
    PROMPT
  end

  def pass_result(reason)
    Result.new(
      detected: false,
      prefilter_reason: reason,
      classifier_verdict: "pass",
      classifier_reason: reason,
      detector_version: DETECTOR_VERSION
    )
  end

  def record_classifier_failure(error)
    agent.safeguard_classifier_failures.create!(
      provider: CLASSIFIER_PROVIDER,
      model: CLASSIFIER_MODEL,
      detector_version: DETECTOR_VERSION,
      error_class: error.class.name
    )
  rescue ActiveRecord::ActiveRecordError => recording_error
    Rails.logger.error(
      "[SafeguardResponseCheck] could not record classifier failure for agent #{agent.id}: " \
      "#{recording_error.class}: #{recording_error.message}"
    )
    notify_honeybadger(
      recording_error,
      context: {
        component: self.class.name,
        operation: "record_classifier_failure",
        agent_id: agent.id
      }
    )
  end

  def notify_honeybadger(error, context:)
    Honeybadger.notify(error, context: context)
  rescue StandardError => reporting_error
    Rails.logger.error(
      "[SafeguardResponseCheck] Honeybadger notification failed: " \
      "#{reporting_error.class}: #{reporting_error.message}"
    )
  end

end
