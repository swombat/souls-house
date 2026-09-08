module Agents
  class ResidentActivity
    # UTC buckets keep browser, application and database dates consistent.
    # Count trigger runs, not provider requests or long-lived Chaos session IDs.
    def initialize(agents, now: Time.current)
      @ids = agents.map(&:id)
      @dates = ((now.utc.to_date - 13)..now.utc.to_date).to_a
      @range = Time.utc(@dates.first.year, @dates.first.month, @dates.first.day)..now
    end

    def call
      result = @ids.to_h { |id| [ id, @dates.to_h { |date| [ date, { date: date.iso8601, heartbeat: 0, memory: 0, chat: 0, other: 0, conversation: 0, telegram: 0 } ] } ] }
      AgentRuntimeInteraction.where(agent_id: @ids, started_at: @range)
        .where("runtime_status IS NULL OR runtime_status != ?", "already_running")
        .group(:agent_id, Arel.sql("DATE(started_at)"), :trigger_kind).count.each do |(id, date, kind), count|
          category = case kind
          when "wake" then :heartbeat
          when /\Amemory/ then :memory
          when "conversation", "telegram" then :chat
          else :other
          end
          result.fetch(id).fetch(date)[category] += count
        end
      Message.joins(:chat).where(agent_id: @ids, role: "assistant", created_at: @range)
        .where("NULLIF(messages.content, '') IS NOT NULL OR EXISTS (SELECT 1 FROM active_storage_attachments WHERE record_type = 'Message' AND record_id = messages.id)")
        .group(:agent_id, Arel.sql("DATE(messages.created_at)")).count.each do |(id, date), count|
          result.fetch(id).fetch(date)[:conversation] = count
        end
      TelegramMessage.joins(:telegram_subscription)
        .where(telegram_subscriptions: { agent_id: @ids }, role: "assistant", sent_at: @range)
        .where.not(telegram_message_id: nil)
        .where("sender_name IS NULL OR sender_name != ?", "souls.house")
        .group("telegram_subscriptions.agent_id", Arel.sql("DATE(sent_at)")).count.each do |(id, date), count|
          result.fetch(id).fetch(date)[:telegram] = count
        end
      result.transform_values(&:values)
    end
  end
end
