# Offline dataset for the stalled-thread sweeper (build thread BjZQAe).
#
#   bin/rails runner script/stalled_sweeper/dataset.rb ACCOUNT_ID OUT.jsonl [MIN_GAP_MINUTES]
#
# For every room in the account, every gap of at least MIN_GAP_MINUTES (default
# 10) between consecutive messages becomes one row: the snapshot the sweeper
# would have been shown at a sweep time inside the gap, built by
# StalledThreadSnapshot as of that time, and an `annotation` envelope with
# what happened next. The envelope is for labelling only; the prompt never
# sees it. The `suggested` label is a first pass from the next messages, not
# a label: what happened next suggests what was owed, it doesn't prove it.
#
# The output holds private conversation text. It stays off git.
account = Account.find(ARGV.fetch(0))
out_path = ARGV.fetch(1)
min_gap = (ARGV[2] || 10).to_i.minutes
out = out_path == "-" ? $stdout : File.open(out_path, "w")

NUDGE = /\b(status|update|any news|what happened|where are we|did you|have you|go on|carry on|continue|proceed|ping|still waiting|stuck)\b|\?\s*\z/i

def sweep_offset(gap)
  StalledThreadSnapshot.sweep_offset(gap)
end

def bucket(gap)
  case gap
  when ...30.minutes then "10-30m"
  when ...2.hours then "30m-2h"
  when ...12.hours then "2h-12h"
  else "12h+"
  end
end

def brief(message)
  {
    id: message.obfuscated_id,
    author: message.agent&.name || message.user&.full_name || "system",
    author_kind: message.agent_id ? "resident" : (message.user_id ? "person" : "system"),
    at: message.created_at.iso8601,
    content: message.content.to_s.truncate(800)
  }
end

def suggest(before, after)
  return "done_or_abandoned" if after.empty?

  following = after.first
  if following.agent_id
    # A resident resumed with no person in between: it could have acted sooner.
    return "wake:#{following.agent.name}" if before.agent_id || before.user_id.nil?
    return "wake:#{following.agent.name}" # a person spoke and the reply came late
  end
  return "uncertain" unless following.user_id

  if before.agent_id
    NUDGE.match?(following.content.to_s.strip) ? "wake:#{before.agent.name}?" : "person_holds"
  else
    "uncertain"
  end
end

rows = 0
skipped = Hash.new(0)
begin
  file = out
  account.chats.kept.find_each do |chat|
    # Every message, discarded or not: a message discarded later still broke
    # the silence when it was posted. One discarded before the sweep time is
    # skipped (and counted) rather than cut around.
    messages = chat.messages.where(role: %w[user assistant], progress_message: false)
      .includes(:agent, :user).reorder(:created_at, :id).to_a
    messages.each_cons(2).with_index do |(before, nxt), index|
      gap = nxt.created_at - before.created_at
      next if gap < min_gap
      offset = sweep_offset(gap)
      if offset.nil?
        skipped[:no_offset_inside_gap] += 1
        next
      end

      sweep_at = before.created_at + offset
      snapshot = StalledThreadSnapshot.new(chat, at: sweep_at)
      state = snapshot.state
      next if state.nil?
      unless snapshot.last_message.id == before.id
        skipped[:discarded_before_sweep] += 1
        next
      end

      after = messages[(index + 1)..(index + 3)]
      file.puts({
        snapshot_id: "#{chat.obfuscated_id}:#{before.obfuscated_id}",
        chat_id: chat.obfuscated_id,
        chat_title: chat.title,
        sweep_at: sweep_at.iso8601,
        gap_minutes: (gap / 60).round,
        gap_bucket: bucket(gap),
        state: state,
        provenance: snapshot.provenance,
        annotation: {
          suggested: suggest(before, after),
          next_messages: after.map { |m| brief(m) },
          label: nil
        }
      }.to_json)
      rows += 1
    end

    # The open gap: the room is quiet now. Nothing after it to suggest a
    # label, so these are labelled by hand or not at all.
    last = messages.reject(&:discarded?).last
    open_gap = last && Time.current - last.created_at
    if open_gap && open_gap >= min_gap && sweep_offset(open_gap)
      gap = open_gap
      sweep_at = last.created_at + sweep_offset(gap)
      snapshot = StalledThreadSnapshot.new(chat, at: sweep_at)
      state = snapshot.state
      if state
        file.puts({
          snapshot_id: "#{chat.obfuscated_id}:#{last.obfuscated_id}",
          chat_id: chat.obfuscated_id, chat_title: chat.title,
          sweep_at: sweep_at.iso8601, gap_minutes: (gap / 60).round, gap_bucket: bucket(gap), open_gap: true,
          state: state, provenance: snapshot.provenance,
          annotation: { suggested: "open", next_messages: [], label: nil }
        }.to_json)
        rows += 1
      end
    end
  end
ensure
  out.close unless out == $stdout
end

warn "#{rows} snapshots written to #{out_path}; skipped #{skipped.to_h}"
