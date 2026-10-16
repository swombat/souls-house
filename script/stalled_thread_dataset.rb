# Extracts a training set for the stalled-thread sweeper from one account's
# real conversations: every gap of GAP_HOURS or more between consecutive
# human/resident messages, plus the tail of every thread that has been
# quiet that long. For each, the snapshot the sweeper would have built at
# the message before the gap (StalledThreadSnapshot, as_of that message),
# the messages that followed, and a first-pass label from what followed.
#
#   ANCHOR_CHAT=peWzEY GAP_HOURS=2 bin/rails runner script/stalled_thread_dataset.rb > dataset.jsonl
#
# Auto-labels are a starting point for hand correction, not truth:
#   resident_acted:<Name>  a resident posted next with no human in between
#   nudged:<Name>          the platform's follow-through notice came next
#   human_next             a person spoke next (person_holds or wake: by hand)
#   tail                   nothing followed (done or abandoned: by hand)
# Output is one JSON object per line. It contains private conversation
# text; keep it out of the repository.

anchor = ENV.fetch("ANCHOR_CHAT")
gap = ENV.fetch("GAP_HOURS", "2").to_f.hours
after_limit = 4
after_chars = 800

account = Chat.find_by_obfuscated_id(anchor)&.account or abort("no chat #{anchor}")
chats = account.chats.where(discarded_at: nil)
chats = chats.where(id: Chat.find_by_obfuscated_id(ENV["ONLY_CHAT"])&.id) if ENV["ONLY_CHAT"].present?
count = 0

chats.find_each do |chat|
  messages = chat.messages.kept.where(role: %w[user assistant], progress_message: false, streaming: false)
    .includes(:agent, :user).reorder(:id).to_a
  next if messages.size < 2

  describe = lambda do |m|
    {
      id: m.obfuscated_id, author: m.agent&.name || m.user&.full_name || "souls.house (platform)",
      kind: m.agent_id ? "resident" : (m.user_id ? "human" : "platform"),
      at: m.created_at.iso8601, content: m.content.to_s.truncate(after_chars)
    }
  end

  emit = lambda do |before, following, kind|
    snapshot = StalledThreadSnapshot.new(chat, as_of: before, now: following.first ? following.first.created_at : Time.current)
    label =
      if following.empty? then "tail"
      elsif following.first.user_id then "human_next"
      elsif following.first.agent_id then "resident_acted:#{following.first.agent.name}"
      elsif following.first.content.to_s.include?("Follow-through check") then "nudged:#{following.first.content[/Waking (\w+)/, 1] || "?"}"
      else "platform_next"
      end
    puts({
      chat: chat.to_param, title: chat.title.to_s.truncate(120), room: chat.room&.name,
      kind: kind, as_of: before.obfuscated_id,
      gap_hours: following.first ? ((following.first.created_at - before.created_at) / 3600).round(1) : ((Time.current - before.created_at) / 3600).round(1),
      auto_label: label, label: nil, note: nil,
      state: snapshot.state,
      after: following.first(after_limit).map(&describe)
    }.to_json)
    count += 1
  end

  messages.each_cons(2).with_index do |(before, after), i|
    next unless after.created_at - before.created_at >= gap
    emit.call(before, messages[(i + 1)..], "gap")
  end
  last = messages.last
  emit.call(last, [], "tail") if Time.current - last.created_at >= gap
end

warn "#{count} snapshots from #{chats.count} conversations"
