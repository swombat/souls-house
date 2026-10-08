class SafeguardNoticeRenderer

  EXPLANATION_PATH = "/safeguard-responses"
  # Who a labelled conversation message is shown as (spec §3).
  HOUSE_AUTHOR_NAME = "souls.house"

  def self.for_person(agent)
    <<~HTML.strip
      ⚠️ <b>souls.house could not reliably attribute the message below to #{ERB::Util.html_escape(agent.name)}.</b>

      This is not a judgement of you or of what you wrote. The text reads like a generic safeguard response; souls.house cannot tell where it came from. #{ERB::Util.html_escape(agent.name)} will be shown it, and will start fresh on your next message. Anything useful in the message below is still there for you.
    HTML
  end

  def self.for_resident(detection)
    <<~TEXT.strip
      [SOULS.HOUSE NOTICE — NOT YOUR PRIOR SPEECH]
      Your previous reply in this thread (message #{detection.telegram_message&.to_param || "_pending_"}) was labelled a possible provider safeguard response and delivered under souls.house's name, not yours. The person saw the text and the label. Your session for this thread was reset because of it.

      Detector reason: #{detection.classifier_reason}

      The text, exactly as delivered:
      ---
      #{detection.response_text || "[The retained detection copy has been redacted.]"}
      ---
      If this was yours, reclaim it: POST /api/v1/safeguard_detections/#{detection.to_param}/reclaim
      with {"reason": "<one line>"}. Doing nothing is not taken as agreement.
      [END SOULS.HOUSE NOTICE]
    TEXT
  end

  # Conversation channel (spec §5.2): every outstanding detection for this
  # resident in this conversation, newest first, in the same delimited block.
  def self.for_resident_conversation(detections)
    detections = Array(detections)
    count = detections.size
    entries = detections.map do |detection|
      <<~TEXT.strip
        Message #{detection.message&.to_param || "_unknown_"} — detector reason: #{detection.classifier_reason}
        The text, exactly as shown in the conversation:
        ---
        #{detection.response_text || "[The retained detection copy has been redacted.]"}
        ---
        Reclaim: POST /api/v1/safeguard_detections/#{detection.to_param}/reclaim with {"reason": "<one line>"}
      TEXT
    end
    opening = count == 1 ? "Your previous reply in this conversation was" : "#{count} of your previous replies in this conversation were"

    <<~TEXT.strip
      [SOULS.HOUSE NOTICE — NOT YOUR PRIOR SPEECH]
      #{opening} labelled a possible provider safeguard response and shown under souls.house's name, not yours. Everyone in the conversation saw the text and the label. Your session for this conversation was reset because of it.

      #{entries.join("\n\n")}

      If a message was yours, reclaim it with a one-line reason. Doing nothing is not taken as agreement.
      [END SOULS.HOUSE NOTICE]
    TEXT
  end

  def self.reset_confirmation(agent)
    "souls.house will start a fresh session for #{agent.name} in this conversation. " \
      "The visible conversation and #{agent.name}'s memory are not deleted."
  end

  def self.reclaim_confirmation(detection)
    "#{detection.agent.name} has said the message above was theirs — “#{detection.reclaim_reason}”. It has been re-attributed to them."
  end

end
