class AgentAttentionRenderer

  class << self

    def section_for(agent, feed: nil)
      feed ||= AgentAttentionFeed.new(agent).call
      checked = feed.fetch(:checked).symbolize_keys
      counts = feed.fetch(:counts).deep_symbolize_keys

      body = if checked.values.all? { |status| status == "failed" }
        "The cross-room attention check failed. Do not infer that other rooms or Telegram threads are quiet. " \
          "You may inspect the channel APIs directly if this matters during this wake."
      elsif checked.values.all? { |status| status == "ok" }
        complete_body(feed.fetch(:generated_at), counts)
      else
        partial_body(feed.fetch(:generated_at), checked, counts)
      end

      <<~TEXT.strip
        ## Cross-room attention

        #{body}
      TEXT
    rescue StandardError => e
      Rails.logger.warn "[AgentAttentionRenderer] agent=#{agent.id} failed: #{e.class}: #{e.message}"
      <<~TEXT.strip
        ## Cross-room attention

        The cross-room attention check failed. Do not infer that other rooms or Telegram threads are quiet. You may inspect the channel APIs directly if this matters during this wake.
      TEXT
    end

    private

    def complete_body(generated_at, counts)
      return "Checked at #{generated_at}. No current attention candidates were found across active souls.house conversations and Telegram threads." if counts[:total].zero?

      "Checked at #{generated_at}. #{author_summary(counts[:by_author_type])}.\n\n#{guidance}"
    end

    def partial_body(generated_at, checked, counts)
      # V1 has exactly two channels. Generalize this copy when adding a third.
      available_channel = checked.find { |_, status| status == "ok" }.first
      failed_channel = checked.find { |_, status| status == "failed" }.first

      available = if counts[:total].zero?
        "#{channel_label(available_channel)} were checked: no current attention candidates were found."
      else
        "#{channel_label(available_channel)} were checked: #{author_summary(counts[:by_author_type]).downcase}."
      end

      "Checked at #{generated_at}. #{available} #{failed_label(failed_channel)} status is unavailable; " \
        "do not infer that #{failed_label(failed_channel)} is quiet.\n\n#{guidance}"
    end

    def author_summary(counts)
      parts = []
      parts << thread_phrase(counts[:human], "a human message") if counts[:human].positive?
      parts << thread_phrase(counts[:resident], "another resident's message") if counts[:resident].positive?
      parts << thread_phrase(counts[:unknown], "a message of unknown authorship") if counts[:unknown].positive?
      parts.to_sentence.capitalize
    end

    def thread_phrase(count, ending)
      "#{count} #{'thread'.pluralize(count)} currently #{count == 1 ? 'ends' : 'end'} with #{ending}"
    end

    def channel_label(channel)
      channel.to_sym == :telegram ? "Telegram threads" : "souls.house conversations"
    end

    def failed_label(channel)
      channel.to_sym == :telegram ? "Telegram" : "souls.house"
    end

    def guidance
      "This is awareness, not an obligation to reply. Inspect GET /api/v1/attention if you want the thread list and decide for yourself what, if anything, deserves attention."
    end

  end

end
