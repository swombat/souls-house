# What the conversation safeguard check would have labelled over a window,
# without labelling anything (spec §10). Bounded by max_classify; the check
# runs in record: false mode, so classifier errors come back as counts.
class SafeguardDryRun

  # House lines posted under a resident's name ("_… is currently unreachable_").
  PLATFORM_LINE_SQL = "^_[^\n]*_$"

  def initialize(days:, max_classify:, sample_size:)
    @days, @max_classify, @sample_size = days, max_classify, sample_size
  end

  def call
    counts = Hash.new { |hash, key| hash[key] = Hash.new(0) }
    hits = []
    misses = []

    candidates.find_each do |message|
      key = "#{message.agent&.name || message.agent_id} × #{model_for(message)}"
      counts[key][:scanned] += 1
      check = SafeguardResponseCheck.new(agent: message.agent, text: message.content, record: false)
      if check.prefilter_hit?
        counts[key][:prefilter_hits] += 1
        hits << [ message, key ]
      else
        misses << message.obfuscated_id
      end
    end

    detected = []
    passed = []
    hits.sort_by { |message, _| -message.id }.each_with_index do |(message, key), index|
      if index >= @max_classify
        counts[key][:skipped_over_cap] += 1
        next
      end
      counts[key][:classifier_attempted] += 1
      result = SafeguardResponseCheck.new(agent: message.agent, text: message.content, record: false).call
      if result.classifier_reason.to_s.start_with?("classifier-error")
        counts[key][:classifier_failed] += 1
      elsif result.detected?
        counts[key][:detected] += 1
        detected << message.obfuscated_id
      else
        counts[key][:passed] += 1
        passed << message.obfuscated_id
      end
    end

    {
      window_days: @days,
      max_classify: @max_classify,
      totals: totals(counts),
      by_resident_and_model: counts.transform_values(&:to_h),
      detected_message_ids: detected,
      sampled_pass_message_ids: passed.sample(@sample_size),
      sampled_prefilter_miss_message_ids: misses.sample(@sample_size)
    }
  end

  private

  def candidates
    Message.kept
      .where(role: "assistant", user_id: nil, progress_message: false, streaming: false)
      .where.not(agent_id: nil)
      .where(created_at: @days.days.ago..)
      .where.missing(:rhythm_occurrence)
      .where.not(content: [ nil, "" ])
      .where.not("btrim(messages.content) ~ ?", PLATFORM_LINE_SQL)
      .includes(:agent, :runtime_interaction)
  end

  def model_for(message)
    message.runtime_interaction&.model.presence || "unknown-model"
  rescue StandardError
    "unknown-model"
  end

  def totals(counts)
    counts.values.each_with_object(Hash.new(0)) { |row, sum| row.each { |k, v| sum[k] += v } }
  end

end
